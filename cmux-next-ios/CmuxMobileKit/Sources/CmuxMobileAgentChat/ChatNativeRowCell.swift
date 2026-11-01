#if os(iOS)
import CmuxMobileDesign
import CmuxMobileMarkdown
import UIKit

/// What a native row's views do with the person's input (links, copy and share of the
/// whole message, showing a long code card in full).
@MainActor
struct ChatNativeActions {
    var openLink: (URL) -> Void = { _ in }
    /// The whole message the block belongs to (nil for the session line).
    var message: (() -> String)?
    var showAll: () -> Void = {}
    /// A tap region's action (disclosures, diffs, the action row).
    var hit: (ChatNativeLayout.Hit) -> Void = { _ in }
    /// The row's long-press menu (nil: none), given the file id of the edit card pressed (a
    /// multi-file snippet), and the action row's "More" menu.
    var menu: ((_ pressedFile: String?) -> UIMenu?)?
    var moreMenu: (() -> UIMenu)?
    /// The files the edited-files card shows as viewed (by index).
    var viewed: Set<Int> = []
}

/// A transcript row drawn by UIKit from a `ChatNativeLayout` laid out off the main thread:
/// it never sizes itself (its height came with the layout) and reuses its views.
@MainActor
final class ChatNativeRowCell: UICollectionViewCell, UIContextMenuInteractionDelegate {
    private var layout: ChatNativeLayout?
    private var actions = ChatNativeActions()
    private var labels: [UILabel] = []
    /// The labels (by index) that show a markdown heading.
    private var headerLabels: Set<Int> = []
    private var symbols: [UIImageView] = []
    private var bars: [UIView] = []
    private var boxes: [UIView] = []
    private var separators: [UIView] = []
    private var scrollers: [ChatLineScroller] = []
    private var hits: [ChatNativeLayout.HitArea] = []
    private var moreButton: UIButton?
    private var copiedReset: Task<Void, Never>?
    private let rule = UIView()
    private var codeCard: ChatCodeCardView?
    private var table: ChatTableView?
    private let margin: CGFloat = 20
    #if DEBUG
    var costKind = "native"
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        rule.backgroundColor = .separator
        rule.isHidden = true
        contentView.addSubview(rule)
        // A layer's border color is a resolved CGColor: re-resolve it when light and dark switch.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: ChatNativeRowCell, _: UITraitCollection) in
            cell.updateBorderColors()
        }
        contentView.addInteraction(UIContextMenuInteraction(delegate: self))
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        contentView.addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ layout: ChatNativeLayout, actions: ChatNativeActions) {
        self.layout = layout
        self.actions = actions
        var usedLabels = 0, usedSymbols = 0, usedBars = 0, usedBoxes = 0, usedSeparators = 0, usedScrollers = 0
        copiedReset?.cancel()
        hits = []
        moreButton?.isHidden = true
        isAccessibilityElement = false
        accessibilityLabel = nil
        accessibilityElements = nil
        codeCard?.isHidden = true
        table?.isHidden = true
        rule.isHidden = true
        switch layout.content {
        case .drawn(let drawn):
            for box in drawn.boxes {
                let view = usedBoxes < boxes.count ? boxes[usedBoxes] : newBox()
                usedBoxes += 1
                view.frame = box.frame.offsetBy(dx: margin, dy: 0)
                view.backgroundColor = box.fill
                view.layer.cornerRadius = box.radius
                view.layer.borderWidth = box.bordered ? 0.5 : 0
                view.layer.borderColor = Self.borderColor(traitCollection)
                view.isHidden = false
            }
            for line in drawn.separators {
                let view = usedSeparators < separators.count ? separators[usedSeparators] : newSeparator()
                usedSeparators += 1
                view.frame = line.offsetBy(dx: margin, dy: 0)
                view.isHidden = false
            }
            for scroller in drawn.scrollers {
                let view = usedScrollers < scrollers.count ? scrollers[usedScrollers] : newScroller()
                usedScrollers += 1
                view.frame = scroller.frame.offsetBy(dx: margin, dy: 0)
                view.apply(scroller)
                view.isHidden = false
            }
            headerLabels = []
            for text in drawn.texts {
                let label = usedLabels < labels.count ? labels[usedLabels] : newLabel()
                if text.isHeader { headerLabels.insert(usedLabels) }
                usedLabels += 1
                label.attributedText = text.text
                label.frame = text.frame.offsetBy(dx: margin, dy: 0)
                label.isHidden = false
            }
            for symbol in drawn.symbols {
                let view = usedSymbols < symbols.count ? symbols[usedSymbols] : newSymbol()
                usedSymbols += 1
                view.image = ChatSymbols.image(symbol.name, symbol.font)
                view.tintColor = symbol.color
                view.frame = symbol.frame.offsetBy(dx: margin, dy: 0)
                view.isHidden = false
            }
            for bar in drawn.bars {
                let view = usedBars < bars.count ? bars[usedBars] : newBar()
                usedBars += 1
                view.frame = bar.offsetBy(dx: margin, dy: 0)
                view.isHidden = false
            }
            if let line = drawn.rule {
                rule.frame = line.offsetBy(dx: margin, dy: 0)
                rule.isHidden = false
            }
            for mark in drawn.viewedMarks where actions.viewed.contains(mark.file) && mark.symbol < symbols.count {
                let view = symbols[mark.symbol]
                view.image = UIImage(systemName: "checkmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13))
                view.tintColor = .cmuxMobileSuccess
            }
            hits = drawn.hits.map { area in
                var area = area
                area.frame = area.frame.offsetBy(dx: margin, dy: 0)
                return area
            }
            if let frame = drawn.menuButton, let more = actions.moreMenu {
                let button = moreButton ?? {
                    let button = UIButton(type: .custom)
                    button.showsMenuAsPrimaryAction = true
                    button.accessibilityLabel = "More"
                    button.accessibilityTraits = .button
                    contentView.addSubview(button)
                    moreButton = button
                    return button
                }()
                button.frame = frame.offsetBy(dx: margin, dy: 0)
                // Built when opened, not per configure.
                button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { completion in completion([more()]) }])
                button.isHidden = false
            }
            accessibilityElements = accessibilityTree(usedLabels: usedLabels, usedScrollers: usedScrollers)
        case .code(let code):
            let card = codeCard ?? {
                let card = ChatCodeCardView()
                contentView.addSubview(card)
                codeCard = card
                return card
            }()
            card.frame = CGRect(x: margin, y: 0, width: contentView.bounds.width - margin * 2, height: code.cardHeight)
            card.apply(code) { [weak self] in self?.actions.showAll() }
            card.isHidden = false
            accessibilityElements = [card]
        case .table(let layout):
            let view = table ?? {
                let view = ChatTableView()
                contentView.addSubview(view)
                table = view
                return view
            }()
            // Bleeds to the screen edges; the content keeps 8 pt at each end.
            view.frame = CGRect(x: 0, y: 0, width: contentView.bounds.width, height: layout.contentSize.height)
            let openLink = actions.openLink
            view.apply(layout, inset: margin - 8, openLink: openLink)
            view.isHidden = false
            accessibilityElements = [view]
        }
        for index in usedBoxes..<boxes.count { boxes[index].isHidden = true }
        for index in usedSeparators..<separators.count { separators[index].isHidden = true }
        for index in usedScrollers..<scrollers.count { scrollers[index].isHidden = true }
        for index in usedLabels..<labels.count { labels[index].isHidden = true }
        for index in usedSymbols..<symbols.count { symbols[index].isHidden = true }
        for index in usedBars..<bars.count { bars[index].isHidden = true }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A width change lays the row out again; until then keep the card and table on the cell's width.
        if let codeCard, !codeCard.isHidden { codeCard.frame.size.width = contentView.bounds.width - margin * 2 }
        if let table, !table.isHidden { table.frame.size.width = contentView.bounds.width }
    }

    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        guard let layout, abs(layout.height - attributes.size.height) > 0.25,
              let fitted = attributes.copy() as? UICollectionViewLayoutAttributes else { return attributes }
        fitted.size.height = layout.height
        return fitted
    }

    private func newLabel() -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        // Text is drawn on a background thread at commit, as the Feed's rows do.
        label.layer.drawsAsynchronously = true
        contentView.addSubview(label)
        labels.append(label)
        return label
    }

    private func newSymbol() -> UIImageView {
        let view = UIImageView()
        view.contentMode = .center
        contentView.addSubview(view)
        symbols.append(view)
        return view
    }

    private func newBox() -> UIView {
        let view = UIView()
        view.layer.cornerCurve = .continuous
        contentView.insertSubview(view, at: 0)
        boxes.append(view)
        return view
    }

    private func newSeparator() -> UIView {
        let view = UIView()
        view.backgroundColor = .separator
        contentView.addSubview(view)
        separators.append(view)
        return view
    }

    private func newScroller() -> ChatLineScroller {
        let view = ChatLineScroller()
        contentView.addSubview(view)
        scrollers.append(view)
        return view
    }

    private func newBar() -> UIView {
        let view = UIView()
        view.backgroundColor = .separator
        view.layer.cornerRadius = 1.5
        contentView.addSubview(view)
        bars.append(view)
        return view
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        let location = tap.location(in: contentView)
        if let match = hits.last(where: { $0.frame.contains(location) }) {
            perform(match.hit)
            return
        }
        if let table, !table.isHidden, let url = table.link(at: tap.location(in: table)) {
            actions.openLink(url)
            return
        }
        for label in labels where !label.isHidden {
            let point = tap.location(in: label)
            guard label.bounds.contains(point), let url = NativeMarkdownView.link(in: label, at: point) else { continue }
            actions.openLink(url)
            return
        }
    }

    /// A tap region's action, from a tap or an assistive technology's activation.
    func perform(_ hit: ChatNativeLayout.Hit) {
        if case .copyAnswer(let index) = hit, index < symbols.count {
            let view = symbols[index]
            let original = view.image
            view.image = UIImage(systemName: "checkmark", withConfiguration: view.image?.symbolConfiguration)
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
            UIAccessibility.post(notification: .announcement, argument: "Copied")
            copiedReset?.cancel()
            copiedReset = Task { @MainActor [weak view] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                view?.image = original
            }
        }
        actions.hit(hit)
    }

    /// The file of the edit card at `location`: the last card header at or above it (each
    /// file's card starts with its Open Diff header).
    private func pressedFile(at location: CGPoint) -> String? {
        var file: String?
        for area in hits where area.frame.minY <= location.y {
            if case .openDiff(let id) = area.hit { file = id }
        }
        return file
    }

    // MARK: Accessibility

    /// What assistive technologies reach in a drawn row, in reading order: each text run not
    /// covered by a tap region (with its links as custom actions), each tap region as a button
    /// with its label, and the More menu.
    private func accessibilityTree(usedLabels: Int, usedScrollers: Int) -> [Any] {
        var items: [(frame: CGRect, element: Any)] = []
        // An edit card's diff lines, read with "Added" and "Removed" for their markers.
        for scroller in scrollers.prefix(usedScrollers) { items.append((scroller.frame, scroller)) }
        for (index, label) in labels.prefix(usedLabels).enumerated() {
            // A list's marker ("•", "3.") is not read on its own; its item is.
            let marker = label.attributedText.map { Self.isListMarker($0.string) } ?? false
            let covered = marker || hits.contains { $0.frame.contains(CGPoint(x: label.frame.midX, y: label.frame.midY)) }
            label.isAccessibilityElement = !covered
            label.accessibilityLabel = label.attributedText?.string
            label.accessibilityCustomActions = covered ? nil : linkActions(label)
            label.accessibilityTraits = (label.accessibilityCustomActions?.isEmpty ?? true) ? .staticText : [.staticText, .link]
            if headerLabels.contains(index) { label.accessibilityTraits.insert(.header) }
            if !covered { items.append((label.frame, label)) }
        }
        for (index, area) in hits.enumerated() {
            let element = ChatHitElement(accessibilityContainer: self)
            element.accessibilityFrameInContainerSpace = area.frame
            var label = area.label
            if let file = area.file, actions.viewed.contains(file) { label += ", viewed" }
            element.accessibilityLabel = label
            element.accessibilityTraits = .button
            if area.isDisclosure { element.accessibilityHint = "Shows details" }
            element.activate = { [weak self] in
                guard let self, index < self.hits.count else { return }
                self.perform(self.hits[index].hit)
            }
            items.append((area.frame, element))
        }
        if let more = moreButton, !more.isHidden { items.append((more.frame, more)) }
        return items.sorted { $0.frame.minY != $1.frame.minY ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }.map(\.element)
    }

    /// "Open <link text>" for each link in the label's text.
    private func linkActions(_ label: UILabel) -> [UIAccessibilityCustomAction]? {
        Self.linkActions(label) { [weak self] url in self?.actions.openLink(url) }
    }

    /// "Open <link text>" for each link in the label's text (a row's text runs, a table's cells).
    static func linkActions(_ label: UILabel, open: @escaping (URL) -> Void) -> [UIAccessibilityCustomAction]? {
        guard let text = label.attributedText, text.length > 0 else { return nil }
        var actions: [UIAccessibilityCustomAction] = []
        text.enumerateAttribute(NativeMarkdownLayout.linkKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let url = value as? URL else { return }
            let name = (text.string as NSString).substring(with: range).trimmingCharacters(in: .whitespaces)
            actions.append(UIAccessibilityCustomAction(name: "Open \(name)") { _ in
                open(url)
                return true
            })
        }
        return actions.isEmpty ? nil : actions
    }

    static func isListMarker(_ text: String) -> Bool {
        text == "•" || text == "◦" || (text.hasSuffix(".") && !text.dropLast().isEmpty && text.dropLast().allSatisfy(\.isNumber))
    }

    private static func borderColor(_ traits: UITraitCollection) -> CGColor {
        UIColor.separator.withAlphaComponent(0.5).resolvedColor(with: traits).cgColor
    }

    private func updateBorderColors() {
        for box in boxes where box.layer.borderWidth > 0 { box.layer.borderColor = Self.borderColor(traitCollection) }
    }

    #if DEBUG
    /// The accessibility tree as text (the rig's `CMUX_MOBILE_CHAT_AXLOG=1` check).
    func accessibilityDescription() -> String {
        func flatten(_ items: [Any]) -> [Any] {
            items.flatMap { item -> [Any] in
                if let container = item as? NSObject, let inner = container.accessibilityElements, !inner.isEmpty { return flatten(inner) }
                return [item]
            }
        }
        let elements = flatten(accessibilityElements ?? [])
        return elements.map { item -> String in
            guard let element = item as? NSObject else { return "?" }
            let actions = element.accessibilityCustomActions?.map(\.name).joined(separator: ",") ?? ""
            let traits = element.accessibilityTraits.contains(.button) ? "button" : (element.accessibilityTraits.contains(.link) ? "link" : "text")
            return "[\(traits)] \(element.accessibilityLabel ?? "")" + (actions.isEmpty ? "" : " {\(actions)}")
        }.joined(separator: " | ")
    }
    #endif

    // MARK: Menu

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let layout else { return nil }
        var items: [UIMenuElement] = []
        switch layout.content {
        case .code(let code):
            items = [
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = code.code },
                UIAction(title: "Copy as Markdown", image: UIImage(systemName: "text.document")) { _ in
                    UIPasteboard.general.string = "```\(code.language ?? "")\n\(code.code)\n```"
                },
                UIAction(title: "Select Text", image: UIImage(systemName: "selection.pin.in.out")) { _ in ChatSelectText.present(code.code) },
                UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in ChatShare.present(code.code) },
            ]
        case .table(let table):
            items = [UIAction(title: "Copy Table", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = table.plainText }]
        case .drawn:
            if let menu = actions.menu {
                guard let built = menu(pressedFile(at: location)) else { return nil }
                return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in built }
            }
            guard let message = actions.message else { return nil }
            items = Self.messageMenu(message)
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in UIMenu(children: items) }
    }

    /// An answer block's long-press menu: the whole message, copied, selected from or shared
    /// (the SwiftUI blocks' text selection becomes Select Text, as on a prompt).
    static func messageMenu(_ message: @escaping () -> String) -> [UIMenuElement] {
        [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = message() },
            UIAction(title: "Select Text", image: UIImage(systemName: "selection.pin.in.out")) { _ in ChatSelectText.present(message()) },
            UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in ChatShare.present(message()) },
        ]
    }
}

/// `CodeCard` in UIKit: the code background, a 0.5 pt border and 20 pt continuous corners, a
/// 40 pt header with the language and a copy button, the code in a horizontal scroll area
/// with a trailing fade while more is off screen, and "Show all N lines" over a fade when capped.
@MainActor
final class ChatCodeCardView: UIView, UIScrollViewDelegate {
    private let glyph = UIImageView()
    private let title = UILabel()
    private let copy = UIButton(type: .system)
    private let scroll = UIScrollView()
    private let body = UILabel()
    private let fade = CAGradientLayer()
    private let capFade = CAGradientLayer()
    private let capView = UIView()
    private let showAll = UIButton(type: .system)
    private var code = ""
    private var capped = false
    private var showAllAction: () -> Void = {}
    private var copiedReset: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .cmuxMobileCodeBackground
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        clipsToBounds = true
        glyph.tintColor = .secondaryLabel
        glyph.contentMode = .center
        title.lineBreakMode = .byTruncatingMiddle
        copy.tintColor = .secondaryLabel
        copy.addTarget(self, action: #selector(copyCode), for: .touchUpInside)
        copy.accessibilityLabel = "Copy code"
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.delegate = self
        body.numberOfLines = 0
        body.layer.drawsAsynchronously = true
        scroll.addSubview(body)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        scroll.layer.mask = fade
        capView.layer.addSublayer(capFade)
        showAll.addTarget(self, action: #selector(showAllTapped), for: .touchUpInside)
        capView.addSubview(showAll)
        for view in [glyph, title, copy, scroll, capView] as [UIView] { addSubview(view) }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChatCodeCardView, _: UITraitCollection) in view.updateColors() }
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ layout: ChatNativeLayout.Code, showAll action: @escaping () -> Void) {
        code = layout.code
        capped = layout.capped
        showAllAction = action
        let metrics = UIImage.SymbolConfiguration(pointSize: 13)
        glyph.image = UIImage(systemName: layout.symbol, withConfiguration: metrics)
        title.attributedText = layout.title
        setCopied(false)
        body.attributedText = layout.body
        body.frame = CGRect(x: 16, y: 4, width: layout.bodySize.width, height: layout.bodySize.height)
        scroll.contentSize = CGSize(width: layout.bodySize.width + 32, height: 4 + layout.bodySize.height + 16)
        scroll.contentOffset = .zero
        capView.isHidden = !layout.capped
        showAll.setAttributedTitle(layout.showAll, for: .normal)
        // Explicit labels and traits: what assistive technologies reach does not depend on
        // UIKit filling them in.
        title.accessibilityLabel = layout.title.string
        title.accessibilityTraits = .header
        body.isAccessibilityElement = true
        body.accessibilityLabel = layout.code
        body.accessibilityTraits = .staticText
        copy.accessibilityTraits = .button
        showAll.accessibilityLabel = layout.showAll.string
        showAll.accessibilityTraits = .button
        accessibilityElements = [title, body, copy] + (layout.capped ? [showAll] : [])
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let titleHeight = ceil(title.font?.lineHeight ?? 18)
        glyph.frame = CGRect(x: 16, y: 0, width: 16, height: 40)
        let titleWidth = min(title.intrinsicContentSize.width, width - 16 - 22 - 44)
        title.frame = CGRect(x: 16 + 16 + 6, y: (40 - titleHeight) / 2, width: max(titleWidth, 0), height: titleHeight)
        copy.frame = CGRect(x: width - 8 - 38, y: -2, width: 44, height: 44)
        scroll.frame = CGRect(x: 0, y: 40, width: width, height: bounds.height - 40)
        if !capped, scroll.contentSize.width <= width { scroll.contentSize.width = width }
        capView.frame = CGRect(x: 0, y: bounds.height - 88, width: width, height: 88)
        capFade.frame = CGRect(x: 0, y: 0, width: width, height: 48)
        showAll.frame = CGRect(x: 0, y: 48, width: width, height: 40)
        updateFade()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateFade() }

    /// `trailingOverflowFade`: 16 pt at the trailing edge while more code is off screen.
    private func updateFade() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = CGRect(origin: scroll.contentOffset, size: scroll.bounds.size)
        let more = scroll.contentOffset.x + scroll.bounds.width < scroll.contentSize.width - 1
        let width = max(scroll.bounds.width, 1)
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, (more ? UIColor.clear : UIColor.black).cgColor]
        fade.locations = [0, NSNumber(value: Double(1 - 16 / width)), 1]
        CATransaction.commit()
    }

    private func updateColors() {
        layer.borderColor = UIColor.separator.withAlphaComponent(0.5).resolvedColor(with: traitCollection).cgColor
        let background = UIColor.cmuxMobileCodeBackground.resolvedColor(with: traitCollection)
        capFade.colors = [background.withAlphaComponent(0).cgColor, background.cgColor]
        showAll.backgroundColor = background
    }

    private func setCopied(_ copied: Bool) {
        let image = UIImage(systemName: copied ? "checkmark" : "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15))
        copy.setImage(image, for: .normal)
        copy.accessibilityLabel = copied ? "Copied" : "Copy code"
    }

    @objc private func copyCode() {
        UIPasteboard.general.string = code
        setCopied(true)
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
        copiedReset?.cancel()
        copiedReset = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.setCopied(false)
        }
    }

    @objc private func showAllTapped() { showAllAction() }
}

/// `MarkdownTableView` in UIKit: the grid in a horizontal scroll area with a trailing fade.
@MainActor
final class ChatTableView: UIScrollView, UIScrollViewDelegate {
    private var labels: [UILabel] = []
    private var rules: [UIView] = []
    private let fade = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = false
        delegate = self
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer.mask = fade
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The link under `point` (in the table's coordinates), if any cell draws one there.
    func link(at point: CGPoint) -> URL? {
        for label in labels where !label.isHidden {
            let inLabel = convert(point, to: label)
            if label.bounds.contains(inLabel), let url = NativeMarkdownView.link(in: label, at: inLabel) { return url }
        }
        return nil
    }

    func apply(_ table: ChatNativeLayout.Table, inset: CGFloat, openLink: @escaping (URL) -> Void) {
        for (index, cell) in table.cells.enumerated() {
            let label: UILabel
            if index < labels.count {
                label = labels[index]
            } else {
                label = UILabel()
                label.numberOfLines = 0
                label.layer.drawsAsynchronously = true
                addSubview(label)
                labels.append(label)
            }
            label.attributedText = cell.text
            label.accessibilityLabel = cell.text.string
            label.accessibilityCustomActions = ChatNativeRowCell.linkActions(label, open: openLink)
            label.accessibilityTraits = label.accessibilityCustomActions == nil ? .staticText : [.staticText, .link]
            label.frame = cell.frame.offsetBy(dx: inset, dy: 0)
            label.isHidden = false
        }
        accessibilityElements = Array(labels.prefix(table.cells.count))
        for index in table.cells.count..<labels.count { labels[index].isHidden = true }
        for (index, frame) in table.rules.enumerated() {
            let rule: UIView
            if index < rules.count {
                rule = rules[index]
            } else {
                rule = UIView()
                rule.backgroundColor = .separator
                addSubview(rule)
                rules.append(rule)
            }
            rule.frame = frame.offsetBy(dx: inset, dy: 0)
            rule.isHidden = false
        }
        for index in table.rules.count..<rules.count { rules[index].isHidden = true }
        contentSize = CGSize(width: table.contentSize.width + inset * 2, height: table.contentSize.height)
        contentOffset = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateFade()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateFade() }

    private func updateFade() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = CGRect(origin: contentOffset, size: bounds.size)
        let more = contentOffset.x + bounds.width < contentSize.width - 1
        let width = max(bounds.width, 1)
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, (more ? UIColor.clear : UIColor.black).cgColor]
        fade.locations = [0, NSNumber(value: Double(1 - 16 / width)), 1]
        CATransaction.commit()
    }
}
#endif

#if os(iOS)
/// Diff lines that scroll sideways under a card's header, with `trailingOverflowFade`.
@MainActor
final class ChatLineScroller: UIScrollView, UIScrollViewDelegate {
    private let label = UILabel()
    private let fade = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = false
        delegate = self
        label.numberOfLines = 0
        label.layer.drawsAsynchronously = true
        addSubview(label)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer.mask = fade
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The diff lines as VoiceOver reads them: each line with "Added" or "Removed" for its
    /// marker (built when read, not per configure).
    override var accessibilityLabel: String? {
        get { label.attributedText.map { Self.spoken($0.string) } }
        set {}
    }

    static func spoken(_ lines: String) -> String {
        lines.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if line.hasPrefix("+\t") { return "Added: " + line.dropFirst(2) }
            if line.hasPrefix("−\t") { return "Removed: " + line.dropFirst(2) }
            if line.hasPrefix(" \t") { return String(line.dropFirst(2)) }
            return String(line)
        }.joined(separator: "\n")
    }

    func apply(_ scroller: ChatNativeLayout.Scroller) {
        label.attributedText = scroller.text.text
        label.frame = scroller.text.frame
        contentSize = CGSize(width: max(scroller.contentWidth, bounds.width), height: scroller.frame.height)
        contentOffset = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if contentSize.width < bounds.width { contentSize.width = bounds.width }
        updateFade()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateFade() }

    private func updateFade() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = CGRect(origin: contentOffset, size: bounds.size)
        let more = contentOffset.x + bounds.width < contentSize.width - 1
        let width = max(bounds.width, 1)
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, (more ? UIColor.clear : UIColor.black).cgColor]
        fade.locations = [0, NSNumber(value: Double(1 - 16 / width)), 1]
        CATransaction.commit()
    }
}
#endif

#if os(iOS)
/// A tap region of a drawn row as an accessibility button.
final class ChatHitElement: UIAccessibilityElement {
    var activate: (@MainActor () -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let activate else { return false }
        MainActor.assumeIsolated { activate() }
        return true
    }
}
#endif
