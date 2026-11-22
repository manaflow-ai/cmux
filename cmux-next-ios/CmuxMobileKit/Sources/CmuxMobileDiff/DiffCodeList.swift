#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// The diff file screen's rows: one `UICollectionView` cell per line (or per split pair, hunk
/// header, gap, "Expand N lines"), laid out from the prepared `DiffRenderModel`. Unwrapped
/// unified code scrolls sideways as one: the collection view's content is as wide as the
/// longest line, and the gutter and band labels are pinned by moving them in the visible
/// cells only (no SwiftUI body per pan frame, no per-row horizontal scroll view).
struct DiffCodeList: UIViewRepresentable {
    let model: DiffRenderModel
    /// The line Search in File shows now (an accent bar at its leading edge).
    var currentLine: Int?
    /// Next / Previous Hunk and Search: the line to scroll to.
    var scrollTarget: DiffScrollTarget?
    let onExpand: (ClosedRange<Int>) -> Void

    func makeCoordinator() -> DiffCodeListController { DiffCodeListController() }

    func makeUIView(context: Context) -> UICollectionView {
        context.coordinator.collectionView
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.onExpand = onExpand
        context.coordinator.apply(model)
        context.coordinator.show(currentLine: currentLine)
        context.coordinator.reveal(scrollTarget)
    }
}

/// A line to scroll the diff list to; a new serial scrolls to the same line again.
struct DiffScrollTarget: Equatable {
    var line: Int
    var serial: Int
}

@MainActor
final class DiffCodeListController: NSObject, UICollectionViewDelegate {
    let layout = DiffCodeLayout()
    private(set) lazy var collectionView: UICollectionView = makeCollectionView()
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
    private(set) var model: DiffRenderModel?
    var onExpand: ((ClosedRange<Int>) -> Void)?
    /// The horizontal offset the pinned parts follow.
    private var pinnedX: CGFloat = 0
    /// The line Search in File shows now.
    private var currentLine: Int?
    /// A scroll waiting for a model whose rows show its line (an unfold being prepared).
    private var pendingScroll: DiffScrollTarget?
    private var scrolledSerial: Int?

    private func makeCollectionView() -> UICollectionView {
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .systemBackground
        view.isDirectionalLockEnabled = true
        view.alwaysBounceVertical = true
        view.alwaysBounceHorizontal = false
        view.showsHorizontalScrollIndicator = true
        view.contentInsetAdjustmentBehavior = .automatic
        view.topEdgeEffect.style = .hard
        view.delegate = self
        let line = UICollectionView.CellRegistration<DiffLineCell, String> { [weak self] cell, _, id in
            self?.configure(cell, id: id)
        }
        let band = UICollectionView.CellRegistration<DiffBandCell, String> { [weak self] cell, _, id in
            self?.configure(cell, id: id)
        }
        let split = UICollectionView.CellRegistration<DiffSplitCell, String> { [weak self] cell, _, id in
            self?.configure(cell, id: id)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: view) { [weak self] collectionView, indexPath, id in
            switch self?.row(id) {
            case .line?: collectionView.dequeueConfiguredReusableCell(using: line, for: indexPath, item: id)
            case .split?: collectionView.dequeueConfiguredReusableCell(using: split, for: indexPath, item: id)
            default: collectionView.dequeueConfiguredReusableCell(using: band, for: indexPath, item: id)
            }
        }
        return view
    }

    private func row(_ id: String) -> DiffRows.Row? {
        guard let model, let index = model.indexByID[id] else { return nil }
        return model.rows.rows[index]
    }

    /// Shows `model`: an expansion (same content) inserts rows with animation, a width change
    /// only lays out again, anything else reloads.
    func apply(_ model: DiffRenderModel) {
        guard model !== self.model else { return }
        let previous = self.model
        self.model = model
        layout.model = model
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(model.ids)
        guard let dataSource else { return }
        if let previous, previous.key.contentKey == model.key.contentKey {
            if previous.ids == model.ids {
                // A new width: the same rows at new heights (wrap indents can change the text).
                layout.invalidateLayout()
                reconfigureVisible()
            } else {
                // An expansion: lines keep their ids and content; bands that kept an id may
                // read differently (a merged hunk's header, a smaller "Expand N lines").
                let kept = model.ids.filter { id in
                    guard let first = id.first, first != "l", first != "s" else { return false }
                    return previous.indexByID[id] != nil
                }
                snapshot.reconfigureItems(kept)
                dataSource.apply(snapshot, animatingDifferences: UIView.areAnimationsEnabled)
            }
        } else {
            if previous?.key.fileID != model.key.fileID {
                pendingScroll = nil
                collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
            }
            dataSource.applySnapshotUsingReloadData(snapshot)
        }
        pin(collectionView)
    }

    private func reconfigureVisible() {
        guard let dataSource else { return }
        for indexPath in collectionView.indexPathsForVisibleItems {
            if let cell = collectionView.cellForItem(at: indexPath) as? DiffCell, let id = dataSource.itemIdentifier(for: indexPath) {
                configure(cell, id: id)
            }
        }
    }

    // MARK: Search and jumps

    func show(currentLine line: Int?) {
        guard line != currentLine else { return }
        currentLine = line
        reconfigureVisible()
    }

    /// Scrolls to `target`'s line at a quarter of the visible height, once the rows show it.
    func reveal(_ target: DiffScrollTarget?) {
        if let target, target.serial != scrolledSerial { pendingScroll = target }
        guard let target = pendingScroll, let model,
              let item = model.rows.rows.firstIndex(where: { $0.shows(line: target.line) }) else { return }
        pendingScroll = nil
        scrolledSerial = target.serial
        collectionView.layoutIfNeeded()
        guard let frame = layout.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame else { return }
        let inset = collectionView.adjustedContentInset
        let visible = collectionView.bounds.height - inset.top - inset.bottom
        let maxY = max(-inset.top, collectionView.contentSize.height + inset.bottom - collectionView.bounds.height)
        let y = min(max(-inset.top, frame.minY - inset.top - visible * 0.25), maxY)
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: y), animated: !UIAccessibility.isReduceMotionEnabled)
    }

    // MARK: Cells

    private func configure(_ cell: DiffCell, id: String) {
        guard let model, let index = model.indexByID[id] else { return }
        let viewport = collectionView.bounds.width
        switch (model.rows.rows[index], cell) {
        case (.line(let line), let cell as DiffLineCell):
            cell.configure(line: model.rows.lines[line], text: model.texts[line], indent: model.indents[line], model: model)
            cell.setCurrentMatch(line == currentLine)
        case (.split(let left, let right), let cell as DiffSplitCell):
            cell.configure(left: left.map { (model.rows.lines[$0], model.texts[$0]) }, right: right.map { (model.rows.lines[$0], model.texts[$0]) },
                           model: model)
            cell.setCurrentMatch(currentLine != nil && (left == currentLine || right == currentLine))
        case (.header(_, let text), let cell as DiffBandCell):
            cell.configure(.header(text), pinned: model.isPinned, viewport: viewport, fonts: model.fonts)
        case (.gap, let cell as DiffBandCell):
            cell.configure(.header("⋯"), pinned: model.isPinned, viewport: viewport, fonts: model.fonts)
        case (.collapsed(let range), let cell as DiffBandCell):
            cell.configure(.collapsed(range.count), pinned: model.isPinned, viewport: viewport, fonts: model.fonts)
        default:
            break
        }
        cell.pin(pinnedX)
    }

    // MARK: Pinning

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        pin(scrollView)
    }

    private func pin(_ scrollView: UIScrollView) {
        let x = model?.isPinned == true ? max(0, scrollView.contentOffset.x + scrollView.adjustedContentInset.left) : 0
        guard x != pinnedX else { return }
        pinnedX = x
        for case let cell as DiffCell in collectionView.visibleCells { cell.pin(x) }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? DiffCell)?.pin(pinnedX)
    }

    // MARK: Taps and menus

    private func row(at indexPath: IndexPath) -> DiffRows.Row? {
        dataSource?.itemIdentifier(for: indexPath).flatMap(row)
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        if case .collapsed? = row(at: indexPath) { return true }
        return false
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        if case .collapsed? = row(at: indexPath) { return true }
        return false
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        if case .collapsed(let range)? = row(at: indexPath) { onExpand?(range) }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let indexPath = indexPaths.first, let model,
              case .line(let index)? = row(at: indexPath) else { return nil }
        let line = model.rows.lines[index]
        // Built on demand, for the pressed line only.
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: [
                UIAction(title: "Copy Line", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = line.text },
                UIAction(title: "Copy with Line Number", image: UIImage(systemName: "number")) { _ in
                    UIPasteboard.general.string = "\(line.newNumber ?? line.oldNumber ?? 0): \(line.text)"
                },
            ])
        })
    }
}

// MARK: Layout

/// Rows stacked at their prepared heights. The content is as wide as the longest unwrapped
/// line (plus the gutter), or the list's width when wrapping. Offsets are summed once per
/// model; a rect query is a binary search, so scrolling costs O(visible rows).
final class DiffCodeLayout: UICollectionViewLayout {
    var model: DiffRenderModel? {
        didSet {
            guard model !== oldValue else { return }
            offsets = []
            invalidateLayout()
        }
    }

    /// `offsets[i]` is row i's top; the last entry is the rows' total height.
    private var offsets: [CGFloat] = []
    static let bottomPadding: CGFloat = 24

    override func prepare() {
        super.prepare()
        guard let model, offsets.count != model.heights.count + 1 else { return }
        var offsets: [CGFloat] = []
        offsets.reserveCapacity(model.heights.count + 1)
        var y: CGFloat = 0
        for height in model.heights {
            offsets.append(y)
            y += height
        }
        offsets.append(y)
        self.offsets = offsets
    }

    private var contentWidth: CGFloat {
        let width = collectionView?.bounds.width ?? 0
        guard let model, model.isPinned else { return width }
        return max(width, DiffLayout.gutterWidth + model.codeWidth)
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: contentWidth, height: (offsets.last ?? 0) + Self.bottomPadding)
    }

    private func attributes(_ index: Int, width: CGFloat) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
        attributes.frame = CGRect(x: 0, y: offsets[index], width: width, height: offsets[index + 1] - offsets[index])
        return attributes
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let count = offsets.count - 1
        guard count > 0 else { return [] }
        // The first row whose bottom is below rect.minY.
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if offsets[mid + 1] <= rect.minY { low = mid + 1 } else { high = mid }
        }
        let width = contentWidth
        var result: [UICollectionViewLayoutAttributes] = []
        var index = low
        while index < count, offsets[index] < rect.maxY {
            result.append(attributes(index, width: width))
            index += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item < offsets.count - 1 else { return nil }
        return attributes(indexPath.item, width: contentWidth)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}

// MARK: Cells

/// A diff cell whose gutter or band label stays put while the code pans sideways.
@MainActor
protocol DiffCell: UICollectionViewCell {
    func pin(_ x: CGFloat)
}

private extension DiffLine {
    var uiRowColor: UIColor {
        switch kind {
        case .added: .cmuxMobileDiffAddRow
        case .removed: .cmuxMobileDiffDelRow
        case .context: .clear
        }
    }

    var uiGutterColor: UIColor {
        switch kind {
        case .added: .cmuxMobileDiffAddGutter
        case .removed: .cmuxMobileDiffDelGutter
        case .context: .clear
        }
    }

    var uiMarkerColor: UIColor {
        switch kind {
        case .added: .cmuxMobileDiffAddText
        case .removed: .cmuxMobileDiffDelText
        case .context: .secondaryLabel
        }
    }
}

@MainActor
private func numberLabel() -> UILabel {
    let label = UILabel()
    label.textColor = .tertiaryLabel
    label.textAlignment = .right
    label.lineBreakMode = .byClipping
    return label
}

/// A unified line: old and new numbers and the ± marker (the gutter), then the code.
final class DiffLineCell: UICollectionViewCell, DiffCell {
    private let gutter = UIView()
    private let gutterRow = UIView()
    private let gutterBand = UIView()
    private let oldLabel = numberLabel()
    private let newLabel = numberLabel()
    private let markerLabel = UILabel()
    private let codeLabel = UILabel()
    /// Search in File's current match: an accent bar at the gutter's leading edge.
    private let matchBar = UIView()
    private var pinnedX: CGFloat = 0
    private var wraps = false
    private var indent: CGFloat = 0
    private var fonts: DiffFonts?

    override init(frame: CGRect) {
        super.init(frame: frame)
        markerLabel.textAlignment = .center
        codeLabel.lineBreakMode = .byWordWrapping
        contentView.addSubview(codeLabel)
        gutter.backgroundColor = .systemBackground
        gutter.addSubview(gutterRow)
        gutter.addSubview(gutterBand)
        [oldLabel, newLabel, markerLabel].forEach(gutter.addSubview)
        matchBar.backgroundColor = .cmuxMobileAccent
        matchBar.isHidden = true
        gutter.addSubview(matchBar)
        contentView.addSubview(gutter)
        isAccessibilityElement = true
    }

    func setCurrentMatch(_ isCurrent: Bool) {
        matchBar.isHidden = !isCurrent
        accessibilityTraits = isCurrent ? .selected : []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(line: DiffLine, text: NSAttributedString, indent: CGFloat, model: DiffRenderModel) {
        wraps = model.style.wrap
        self.indent = indent
        fonts = model.fonts
        contentView.backgroundColor = line.uiRowColor
        // Unwrapped, the gutter covers the code panning under it: opaque, row color on top.
        gutter.backgroundColor = wraps ? .clear : .systemBackground
        gutterRow.backgroundColor = wraps ? .clear : line.uiRowColor
        gutterBand.backgroundColor = line.uiGutterColor
        oldLabel.font = model.fonts.number
        newLabel.font = model.fonts.number
        oldLabel.text = line.oldNumber.map(String.init)
        newLabel.text = line.newNumber.map(String.init)
        markerLabel.font = wraps ? model.fonts.code : model.fonts.marker
        markerLabel.text = line.marker
        markerLabel.textColor = line.uiMarkerColor
        codeLabel.numberOfLines = wraps ? 0 : 1
        codeLabel.attributedText = text
        accessibilityLabel = line.accessibilityText
        setNeedsLayout()
    }

    func pin(_ x: CGFloat) {
        let x = wraps ? 0 : x
        guard x != pinnedX else { return }
        pinnedX = x
        gutter.frame.origin.x = x
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let numberWidth = DiffLayout.numberWidth
        let numberCell = numberWidth + DiffLayout.numberTrailingPadding
        gutter.frame = CGRect(x: wraps ? 0 : pinnedX, y: 0, width: DiffLayout.gutterWidth, height: bounds.height)
        gutterRow.frame = gutter.bounds
        gutterBand.frame = CGRect(x: 0, y: 0, width: numberCell * 2, height: bounds.height)
        matchBar.frame = CGRect(x: 0, y: 0, width: 3, height: bounds.height)
        if wraps, let fonts {
            // Top aligned: the numbers share the first line's baseline.
            let numberY = 2 + (fonts.code.ascender - fonts.number.ascender)
            let numberHeight = ceil(fonts.number.lineHeight)
            oldLabel.frame = CGRect(x: 0, y: numberY, width: numberWidth, height: numberHeight)
            newLabel.frame = CGRect(x: numberCell, y: numberY, width: numberWidth, height: numberHeight)
            markerLabel.frame = CGRect(x: numberCell * 2, y: 2, width: DiffLayout.markerWidth, height: ceil(fonts.code.lineHeight))
            let x = DiffLayout.gutterWidth + indent
            codeLabel.frame = CGRect(x: x, y: 2, width: max(0, bounds.width - x - DiffLayout.codeTrailingPadding), height: max(0, bounds.height - 4))
        } else {
            oldLabel.frame = CGRect(x: 0, y: 0, width: numberWidth, height: bounds.height)
            newLabel.frame = CGRect(x: numberCell, y: 0, width: numberWidth, height: bounds.height)
            markerLabel.frame = CGRect(x: numberCell * 2, y: 0, width: DiffLayout.markerWidth, height: bounds.height)
            // As wide as the text, not the row: a short line keeps a small backing store.
            let x = DiffLayout.gutterWidth + 2
            let textWidth = ceil(CGFloat(codeLabel.attributedText?.length ?? 0) * (fonts?.advancement ?? 8)) + 2
            codeLabel.frame = CGRect(x: x, y: 0, width: max(0, min(bounds.width - x, textWidth)), height: bounds.height)
        }
    }
}

/// A hunk header, a gap between parsed hunks, or "Expand N lines".
final class DiffBandCell: UICollectionViewCell, DiffCell {
    enum Content: Equatable {
        case header(String)
        case collapsed(Int)
    }

    private let label = UILabel()
    private let icon = UIImageView(image: UIImage(systemName: "arrow.up.and.down"))
    private var content: Content = .header("")
    private var pinned = false
    private var viewport: CGFloat = 0
    private var pinnedX: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .cmuxMobileDiffHunk
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingTail
        icon.tintColor = .secondaryLabel
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        contentView.addSubview(label)
        contentView.addSubview(icon)
        isAccessibilityElement = true
        let highlight = UIView()
        highlight.backgroundColor = .systemFill
        selectedBackgroundView = highlight
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ content: Content, pinned: Bool, viewport: CGFloat, fonts: DiffFonts) {
        self.content = content
        self.pinned = pinned
        self.viewport = viewport
        switch content {
        case .header(let text):
            label.font = fonts.header
            label.text = text
            icon.isHidden = true
            accessibilityLabel = text == "⋯" ? "Lines not shown" : text
            accessibilityTraits = []
        case .collapsed(let count):
            label.font = .preferredFont(forTextStyle: .footnote)
            label.text = count > 40 ? "Expand 20 lines" : "Expand \(count) lines"
            icon.isHidden = false
            accessibilityLabel = "Expand \(count) hidden lines"
            accessibilityTraits = .button
        }
        setNeedsLayout()
    }

    func pin(_ x: CGFloat) {
        let x = pinned ? x : 0
        guard x != pinnedX else { return }
        pinnedX = x
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = contentView.bounds.height
        if pinned {
            // The gutter part keeps the icon; the label sits at the code column's start, in view.
            let gutter = DiffLayout.gutterWidth
            icon.frame = CGRect(x: pinnedX, y: 0, width: gutter, height: height)
            let codeViewport = DiffLayout.codeViewport(width: viewport)
            label.frame = CGRect(x: pinnedX + gutter + 8, y: 0, width: max(0, codeViewport - 8), height: height)
        } else {
            let iconWidth = icon.isHidden ? 0 : (icon.image?.size.width ?? 14)
            icon.frame = CGRect(x: 16, y: 0, width: iconWidth, height: height)
            let x = icon.isHidden ? 16 : 16 + iconWidth + 8
            label.frame = CGRect(x: x, y: 0, width: max(0, contentView.bounds.width - x - 16), height: height)
        }
    }
}

/// A split pair: the old line on the left, the new line on the right.
final class DiffSplitCell: UICollectionViewCell, DiffCell {
    private final class Side: UIView {
        let number = numberLabel()
        let code = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(number)
            addSubview(code)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func configure(_ line: (DiffLine, NSAttributedString)?, number value: Int?, wrap: Bool, fonts: DiffFonts) {
            number.font = fonts.number
            number.text = value.map(String.init)
            code.numberOfLines = wrap ? 0 : 1
            code.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
            code.attributedText = line?.1
            switch line?.0.kind {
            case nil: backgroundColor = .cmuxMobileFill
            case .added?: backgroundColor = .cmuxMobileDiffAddRow
            case .removed?: backgroundColor = .cmuxMobileDiffDelRow
            case .context?: backgroundColor = .clear
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            number.frame = CGRect(x: 0, y: 2, width: 32, height: ceil(number.font.lineHeight))
            let width = max(0, bounds.width - DiffRenderModel.splitNumberColumn)
            let fitted = code.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            code.frame = CGRect(x: DiffRenderModel.splitNumberColumn, y: 0, width: width, height: min(bounds.height, ceil(fitted)))
        }
    }

    private let left = Side()
    private let right = Side()
    private let divider = UIView()
    /// Search in File's current match: an accent bar at the row's leading edge.
    private let matchBar = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        divider.backgroundColor = .separator
        matchBar.backgroundColor = .cmuxMobileAccent
        matchBar.isHidden = true
        [left, right, divider, matchBar].forEach(contentView.addSubview)
        isAccessibilityElement = true
    }

    func setCurrentMatch(_ isCurrent: Bool) {
        matchBar.isHidden = !isCurrent
        accessibilityTraits = isCurrent ? .selected : []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(left: (DiffLine, NSAttributedString)?, right: (DiffLine, NSAttributedString)?, model: DiffRenderModel) {
        self.left.configure(left, number: left?.0.oldNumber, wrap: model.style.wrap, fonts: model.fonts)
        self.right.configure(right, number: right?.0.newNumber, wrap: model.style.wrap, fonts: model.fonts)
        accessibilityLabel = [left?.0, right?.0].compactMap { $0 }.reduce(into: [String]()) { labels, line in
            if !labels.contains(line.accessibilityText) { labels.append(line.accessibilityText) }
        }.joined(separator: ", ")
        setNeedsLayout()
    }

    func pin(_ x: CGFloat) {}

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let column = (bounds.width - 1) / 2
        left.frame = CGRect(x: 0, y: 0, width: column, height: bounds.height)
        divider.frame = CGRect(x: column, y: 0, width: 1, height: bounds.height)
        right.frame = CGRect(x: column + 1, y: 0, width: column, height: bounds.height)
        matchBar.frame = CGRect(x: 0, y: 0, width: 3, height: bounds.height)
    }
}
#endif
