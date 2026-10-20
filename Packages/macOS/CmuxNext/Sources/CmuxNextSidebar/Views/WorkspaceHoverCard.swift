import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextResources
import CmuxNextWakeups

/// The workspace hover card (Codex parity, Leo 2026-10-08): a title row
/// (the name, a kind or host icon, the relative age) and one row per
/// meaningful fact (`WorkspaceHoverCardContent`); CPU and memory summed over
/// its tabs show as one muted line, only when notable. It replaces the row
/// tooltip.
///
/// Resources are sampled from hover start (the CPU baseline) until the
/// card hides; nothing is sampled while no card is pending or shown.
final class WorkspaceHoverCardController: HoverCardSource {
    let resources = ResourceCardSampler(source: nil)
    /// Hover time before a card shows: `HoverCardTiming.showDelay`, or
    /// `sidebar.hoverCards.delay` (cx-23e1f), so a sweep down the list shows
    /// none and leaving a row cancels its pending card. Once a card shows,
    /// moving down the list slides it over at once.
    var delay: Duration { DesignSettings.shared.hoverCardDelay }
    /// Lawrence 2026-10-19: "We need it to instantly disappear with fade opacity when I mouse
    /// out." The card touches its row, so it needs no grace for the pointer to travel to it:
    /// leaving the row and the card fades it out at once, as a tab card does. A gap or header
    /// in the list (`hoverCardBridges`) holds it for the reshow window, so the next row slides
    /// it over instead of hiding and reshowing it.
    var leave: HoverCardLeave { .hides(reshow: HoverCardTiming.reshowWindow) }
    weak var list: SidebarListView?
    /// The app's one coordinator; the App injects it.
    var coordinator: HoverCardCoordinator {
        didSet {
            guard coordinator !== oldValue else { return }
            oldValue.unregister(self)
            if list?.window != nil { coordinator.register(self) }
        }
    }
    private var body: WorkspaceHoverCardView?
    private var bodyID: HoverTargetID?
    /// Ticks the shown card's running times once a second (one-shot, re-armed by each tick);
    /// idle while no live card shows, so a quiet sidebar wakes nothing.
    private let ticker = DemandTimer(owner: "sidebar.hover-card.elapsed")
    /// The user's customization (`cmux.hovercard/1`); the App injects it.
    var customization: (any SidebarCustomization)?
    /// The shown card's custom content and its workspace; released when the card hides or moves.
    private var custom: (id: WorkspaceID, content: any SidebarCustomContent)?

    init(coordinator: HoverCardCoordinator = HoverCardCoordinator()) {
        self.coordinator = coordinator
    }

    static func targetID(_ id: WorkspaceID) -> HoverTargetID { HoverTargetID("ws:\(id.rawValue)") }

    private func workspaceID(_ id: HoverTargetID) -> WorkspaceID? {
        id.rawValue.hasPrefix("ws:") ? WorkspaceID(String(id.rawValue.dropFirst(3))) : nil
    }

    /// This list's workspace whose card shows now.
    var shownID: WorkspaceID? {
        guard let id = coordinator.machine.shownTarget?.id, let ws = workspaceID(id), list?.workspaces[ws] != nil else { return nil }
        return ws
    }

    var isVisible: Bool { shownID != nil }

    // MARK: HoverCardSource

    var hoverCardWindow: NSWindow? { list?.window }

    func hoverCardHit(at screenPoint: CGPoint) -> HoverCardHit? {
        guard let list, let window = list.window,
              let id = list.hoverCardWorkspace(at: list.convert(window.convertPoint(fromScreen: screenPoint), from: nil)),
              let anchor = list.hoverCardAnchor(for: id)
        else { return nil }
        return HoverCardHit(target: HoverTarget(id: Self.targetID(id), window: window.windowNumber, delay: delay, leave: leave),
                            anchor: anchor)
    }

    /// A point in the visible list on no row (a header, a gap between rows).
    func hoverCardBridges(at screenPoint: CGPoint) -> Bool {
        guard let list, let window = list.window, !list.isHiddenOrHasHiddenAncestor else { return false }
        return list.visibleRect.contains(list.convert(window.convertPoint(fromScreen: screenPoint), from: nil))
    }

    func hoverCardAnchor(for id: HoverTargetID) -> CGRect? {
        workspaceID(id).flatMap { list?.hoverCardAnchor(for: $0) }
    }

    func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? {
        guard let list, let ws = workspaceID(id), let workspace = list.workspaces[ws] else { return nil }
        let body = body ?? WorkspaceHoverCardView()
        self.body = body
        let machine = list.sections.values.lazy.compactMap(\.machine).first { $0.id == workspace.machineID }
        let content = WorkspaceHoverCardContent.make(workspace, machine: machine, now: Date())
        body.configure(content)
        body.setResources(resources.report)
        bodyID = id
        body.setCustom(customContent(for: ws, id: id, card: content.cardFacts))
        updateTicker()
        return HoverCardBody(view: body, placement: .beside, themeAnchor: list) { [weak body] in body?.applyColors() }
    }

    func hoverCardActivated(_ id: HoverTargetID) {
        guard let ws = workspaceID(id) else { return }
        resources.open(.workspace(ws.rawValue)) { [weak self] report in
            guard let self, self.bodyID == id else { return }
            self.body?.setResources(report)
            self.coordinator.contentChanged(id)
        }
    }

    func hoverCardDeactivated(_ id: HoverTargetID) {
        resources.close()
        bodyID = nil
        releaseCustom()
        updateTicker()
    }

    /// The custom card for `ws`, mounted once per shown card; nil without a customization.
    private func customContent(for ws: WorkspaceID, id: HoverTargetID, card: SidebarCardFacts) -> (any SidebarCustomContent)? {
        if let custom, custom.id == ws { return custom.content }
        releaseCustom()
        guard let content = customization?.hoverCard(forWorkspace: ws.rawValue, card: card) else { return nil }
        content.onChange = { [weak self, weak content] in
            guard let self, let content, self.bodyID == id else { return }
            self.body?.setCustom(content)
            self.coordinator.contentChanged(id)
        }
        custom = (ws, content)
        return content
    }

    private func releaseCustom() {
        custom?.content.onChange = nil
        custom?.content.release()
        custom = nil
    }

    /// Arms the next one-second tick while a card with a running time shows, stops it otherwise.
    private func updateTicker() {
        guard bodyID != nil, let body, let delay = body.nextTickDelay else {
            ticker.cancel()
            return
        }
        guard !ticker.isScheduled else { return }
        ticker.schedule(after: delay) { @MainActor [weak self] in self?.tickShownCard() }
    }

    private func tickShownCard() {
        guard let id = bodyID, let body else { return }
        if body.tick(now: Date()) { coordinator.contentChanged(id) }
        updateTicker()
    }

    /// Design tokens changed: the next card rebuilds at the new sizes.
    func tokensChanged() {
        coordinator.dismiss(.action)
        body = nil
        bodyID = nil
    }
}

/// The workspace card body. One instance is reused for every workspace
/// card; the app's one `HoverCardPanel` hosts it.
final class WorkspaceHoverCardView: NSView {
    private static var padding: CGFloat { Metrics.space4 }
    /// The card sizes to its content between these widths (POLISH: no
    /// blank band beside a short name); a long name wraps at the widest.
    static var cardWidth: CGFloat { 280 }
    static var minCardWidth: CGFloat { 180 }
    private static var iconSize: CGFloat { 13 }
    /// The body font with digits of one width, for lines whose running time ticks.
    private static var liveFont: NSFont { Typography.system(.monospacedDigit, size: Typography.body.pointSize, weight: .regular) }

    /// When the card's running times next change their text: every second under an hour, then
    /// every minute ("1h 3m"); nil when nothing runs.
    var nextTickDelay: Duration? {
        guard isLive, let content else { return nil }
        let starts = ([content.activitySince] + content.facts.map(\.since)).compactMap { $0 }
        guard let newest = starts.max() else { return nil }
        return Date().timeIntervalSince(newest) < 3600 ? .seconds(1) : .seconds(60)
    }

    private let titleLabel = ChromeLabel(labelWithString: "")
    /// The kind or host icon, leading the name on the card's icon column.
    private let kindIcon = LineIconView()
    /// The workspace's status in the shared indicator, on its own row under the name with its
    /// word beside it (Leo 2026-10-13: an unlabeled mark under the name read as a smudge).
    private let activity: StatusIndicatorView = { let view = StatusIndicatorView(); view.tracksWindowOcclusion = true; return view }()
    private let activityLabel = ChromeLabel(labelWithString: "")
    private let activityRow = NSStackView()
    private let ageLabel = ChromeLabel(labelWithString: "")
    private let factsStack = NSStackView()
    private let resourceLabel = ChromeLabel(labelWithString: "")
    /// The user's card (`cmux.hovercard/1`) once its first scene arrives; the built-in rows hide.
    private let customSlot = NSView()
    /// Why the user's card did not render: shown under the built-in card, which stays.
    private let customError = ChromeLabel(wrappingLabelWithString: "")
    private weak var customView: NSView?
    private var customHeight: NSLayoutConstraint?
    /// The last resource line, shown only with the built-in card.
    private var resourceLine: String?
    private var factViews: [(icon: NSImageView, label: ChromeLabel)] = []
    /// The built-in card's rows (hidden while the user's card shows).
    private var builtIn: [NSView] = []
    /// The shown content, for the live elapsed times (`tick`).
    private var content: WorkspaceHoverCardContent?
    /// The shown status word, before its elapsed time.
    private var activityWord: String?

    init() {
        super.init(frame: .zero)
        let content = self
        titleLabel.font = Typography.bodyEmphasized
        // The whole name, wrapped: the card is where a clipped row title
        // reads in full (also under Reduce Motion, which has no marquee).
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 6
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        ageLabel.font = Typography.caption
        ageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        ageLabel.setContentHuggingPriority(.required, for: .horizontal)
        kindIcon.setContentHuggingPriority(.required, for: .horizontal)
        kindIcon.line = titleLabel
        kindIcon.side = Self.iconSize
        // Digits of one width: a running time that ticks keeps its width ("1m 11s", "1m 18s").
        activityLabel.font = Self.liveFont
        activityLabel.lineBreakMode = .byTruncatingTail
        resourceLabel.font = Typography.caption
        resourceLabel.lineBreakMode = .byTruncatingTail

        // Every icon sits on one column at the leading inset, its text beside it (the fact rows'
        // grid), so the kind icon leads the name instead of floating after it.
        let titleRow = NSStackView(views: [kindIcon, titleLabel, ageLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = Metrics.space2
        titleRow.setCustomSpacing(Metrics.space4, after: titleLabel)
        // The indicator's slot is a box that never hides, so a style that draws no glyph keeps the
        // word on the text column.
        let activitySlot = NSView()
        activity.translatesAutoresizingMaskIntoConstraints = false
        activitySlot.addSubview(activity)
        activityRow.setViews([activitySlot, activityLabel], in: .leading)
        activityRow.orientation = .horizontal
        activityRow.alignment = .centerY
        activityRow.spacing = Metrics.space2
        factsStack.orientation = .vertical
        factsStack.alignment = .leading
        factsStack.spacing = Metrics.space2

        customError.font = Typography.caption
        customError.maximumNumberOfLines = 3
        customError.isHidden = true
        customSlot.isHidden = true
        builtIn = [titleRow, activityRow, factsStack, resourceLabel]
        let stack = NSStackView(views: [customSlot, titleRow, activityRow, factsStack, resourceLabel, customError])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space3
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let p = Self.padding
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(lessThanOrEqualToConstant: Self.cardWidth),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minCardWidth),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: p),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -p),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            kindIcon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            kindIcon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            activitySlot.widthAnchor.constraint(equalToConstant: Self.iconSize),
            activitySlot.heightAnchor.constraint(equalToConstant: Self.iconSize),
            activity.widthAnchor.constraint(equalToConstant: Self.iconSize),
            activity.heightAnchor.constraint(equalToConstant: Self.iconSize),
            activity.centerXAnchor.constraint(equalTo: activitySlot.centerXAnchor),
            activity.centerYAnchor.constraint(equalTo: activitySlot.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The text the card shows, one entry per row (tests, accessibility).
    var lines: [String] {
        if !customSlot.isHidden { return ["custom card"] + Self.texts(in: customSlot) }
        var lines = [[titleLabel.stringValue, ageLabel.isHidden ? "" : ageLabel.stringValue]
            .filter { !$0.isEmpty }.joined(separator: " ")]
        if !activityRow.isHidden { lines.append(activityLabel.stringValue) }
        lines += factViews.filter { !$0.label.isHidden }.map(\.label.stringValue)
        if !resourceLabel.isHidden { lines.append(resourceLabel.stringValue) }
        if !customError.isHidden { lines.append(customError.stringValue) }
        return lines
    }

    /// The card shows a running time (the status's or a command's): the controller ticks it.
    var isLive: Bool {
        guard let content else { return false }
        return (activityWord != nil && content.activitySince != nil) || content.facts.contains { $0.since != nil }
    }

    /// Rewrites the running times for `now` (once a second while the card shows). True when a
    /// text got longer or shorter, so the panel measures the card again.
    @discardableResult
    func tick(now: Date) -> Bool {
        guard let content else { return false }
        var resized = false
        func set(_ label: ChromeLabel, _ text: String) {
            resized = resized || label.stringValue.count != text.count
            label.stringValue = text
        }
        if let word = activityWord {
            set(activityLabel, WorkspaceHoverCardContent.withElapsed(word, since: content.activitySince, now: now))
        }
        for (index, fact) in content.facts.enumerated() where fact.since != nil && index < factViews.count {
            set(factViews[index].label, WorkspaceHoverCardContent.withElapsed(fact.text, since: fact.since, now: now))
        }
        return resized
    }

    func configure(_ content: WorkspaceHoverCardContent, now: Date = Date()) {
        self.content = content
        titleLabel.stringValue = content.title
        kindIcon.image = NSImage.icon(content.icon, size: Self.iconSize)
        ageLabel.stringValue = content.age ?? ""
        ageLabel.isHidden = content.age == nil
        activity.configure(content.activity, style: content.activityStyle)
        let word = Strings.activity(content.activity)
        activityWord = word
        activityLabel.stringValue = word.map { WorkspaceHoverCardContent.withElapsed($0, since: content.activitySince, now: now) } ?? ""
        activityRow.isHidden = word == nil
        // The width the title wraps at (the panel sizes the card in one
        // pass): the row less its icon and the age.
        let age = ageLabel.isHidden ? 0 : ageLabel.intrinsicContentSize.width + Metrics.space4
        titleLabel.preferredMaxLayoutWidth = Self.cardWidth - 2 * Self.padding - Self.iconSize - Metrics.space2 - age
        while factViews.count < content.facts.count { addFactRow() }
        for (index, row) in factViews.enumerated() {
            let fact = index < content.facts.count ? content.facts[index] : nil
            row.icon.superview?.isHidden = fact == nil
            row.label.isHidden = fact == nil
            guard let fact else { continue }
            row.icon.image = Self.ownImage(fact) ?? NSImage.icon(fact.icon, size: Self.iconSize)
            row.label.stringValue = WorkspaceHoverCardContent.withElapsed(fact.text, since: fact.since, now: now)
            row.label.font = fact.since == nil ? Typography.body : Self.liveFont
            row.label.maximumNumberOfLines = fact.lines
            row.label.truncatesLastVisibleLine = true
            row.label.lineBreakMode = fact.lines > 1 ? .byWordWrapping : .byTruncatingMiddle
            row.label.preferredMaxLayoutWidth = fact.lines > 1 ? Self.cardWidth - 2 * Self.padding - Self.iconSize - Metrics.space2 : 0
        }
        // The last reply sits a step apart from the metadata above it, like the stack's own gap.
        for (index, row) in factViews.enumerated() {
            guard let view = row.icon.superview else { continue }
            let next = index + 1 < content.facts.count ? content.facts[index + 1] : nil
            factsStack.setCustomSpacing(next?.kind == WorkspaceHoverCardContent.Fact.lastReplyKind ? Metrics.space3 : NSStackView.useDefaultSpacing, after: view)
        }
        factsStack.isHidden = content.facts.isEmpty
        applyColors()
    }

    /// Every text an embedded view shows, by its accessibility (a SwiftUI scene has no labels).
    /// Depth first, a parent before its children, children in order. An explicit stack, not a
    /// recursive local function: Swift 6.3.3's SendNonSendable pass crashed now and then on the
    /// local function's capture of the result (Release compile, CmuxNextSidebar).
    private static func texts(in view: NSView) -> [String] {
        var out: [String] = []
        var pending: [Any] = [view]
        while let element = pending.popLast() {
            guard let object = element as? any NSAccessibilityProtocol else { continue }
            if let role = object.accessibilityRole(), role == .staticText,
               let value = object.accessibilityValue() as? String ?? object.accessibilityLabel(), !value.isEmpty {
                out.append(value)
            }
            // Reversed, so the first child pops first.
            pending.append(contentsOf: (object.accessibilityChildren() ?? []).reversed())
        }
        return out
    }

    /// A status entry's own icon: its stored image, its SF Symbol or its emoji; nil for none (or
    /// an asset not read yet), so the fact's icon draws.
    private static func ownImage(_ fact: WorkspaceHoverCardContent.Fact) -> NSImage? {
        let size = NSSize(width: iconSize, height: iconSize)
        if let image = fact.image { return NSImage(cgImage: image.image, size: size) }
        guard let mark = fact.mark, !mark.isEmpty else { return nil }
        if let symbol = NSImage(systemSymbolName: mark, accessibilityDescription: nil) { return symbol }
        guard !mark.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        return NSImage(size: size, flipped: false) { rect in
            (mark as NSString).draw(in: rect, withAttributes: [.font: Typography.system(size: rect.height * 0.8)])
            return true
        }
    }

    /// Shows the user's card when it rendered, else the built-in card with the error (if any).
    func setCustom(_ content: (any SidebarCustomContent)?) {
        let ready = content.map { $0.isReady && $0.errorText == nil } ?? false
        if let content, ready, customView !== content.view {
            customView?.removeFromSuperview()
            let view = content.view
            view.translatesAutoresizingMaskIntoConstraints = false
            customSlot.addSubview(view)
            let height = customSlot.heightAnchor.constraint(equalToConstant: 0)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: customSlot.topAnchor),
                view.bottomAnchor.constraint(equalTo: customSlot.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: customSlot.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: customSlot.trailingAnchor),
                customSlot.widthAnchor.constraint(equalToConstant: Self.cardWidth - 2 * Self.padding),
                height,
            ])
            customHeight?.isActive = false
            customHeight = height
            customView = view
        }
        // Wrapped text needs the height at the card's width, measured again on every change.
        if ready, let content { customHeight?.constant = content.preferredHeight(width: Self.cardWidth - 2 * Self.padding) }
        if !ready {
            customView?.removeFromSuperview()
            customView = nil
        }
        customSlot.isHidden = !ready
        for view in builtIn { view.isHidden = ready ? true : view.isHidden }
        if !ready {
            builtIn.first?.isHidden = false
            if let content = self.content { configure(content) }
        }
        resourceLabel.isHidden = ready || resourceLine == nil
        let error = content?.errorText
        customError.stringValue = error.map(Strings.customCardError) ?? ""
        customError.isHidden = error == nil || ready
        applyColors()
    }

    func setResources(_ report: ResourceReport?) {
        let line = WorkspaceHoverCardContent.resourceLine(report)
        resourceLine = line
        resourceLabel.stringValue = line ?? ""
        resourceLabel.isHidden = line == nil || !customSlot.isHidden
    }

    private func addFactRow() {
        let icon = NSImageView()
        let label = ChromeLabel(labelWithString: "")
        label.font = Typography.body
        label.lineBreakMode = .byTruncatingMiddle
        // The card takes its width from its content (cx-k9mc).
        label.setContentCompressionResistancePriority(.keepsTextWidth, for: .horizontal)
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.space2
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])
        factsStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: factsStack.widthAnchor).isActive = true
        factViews.append((icon, label))
    }
}

extension WorkspaceHoverCardView: HoverCardTextReporting {
    var reportedLines: [String] { lines }
}

extension WorkspaceHoverCardView {
    /// Recolors the labels in the card's theme scope; the panel runs it on
    /// adopt and on every change of that scope.
    func applyColors() {
        performWithTheme {
            titleLabel.textColor = Palette.textPrimary
            ageLabel.textColor = Palette.textSecondary
            activityLabel.textColor = Palette.textPrimary
            kindIcon.contentTintColor = Palette.textSecondary
            // A clear title, muted metadata, and what was said in the primary ink (Leo 2026-10-19,
            // Claude desktop's session card); no fill of its own, the shared overlay glass shows.
            let facts = content?.facts ?? []
            for (index, row) in factViews.enumerated() {
                let message = index < facts.count && facts[index].isMessage
                row.label.textColor = message ? Palette.textPrimary : Palette.textSecondary
                row.icon.contentTintColor = Palette.textSecondary
            }
            resourceLabel.textColor = Palette.textSecondary
            customError.textColor = Palette.textSecondary
        }
    }
}

/// An icon on a first-baseline row whose center sits on the middle of `line`'s first line (midway
/// between its ascender and descender), so it stays with the name's first line when the name wraps.
private final class LineIconView: NSImageView {
    weak var line: ChromeLabel?
    /// The icon's height (its constraint), not `bounds`, which is zero before the first layout.
    var side: CGFloat = 0

    override var firstBaselineOffsetFromTop: CGFloat {
        guard let font = line?.font else { return super.firstBaselineOffsetFromTop }
        return side / 2 + (font.ascender + font.descender) / 2
    }
}
