import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextWakeups

/// The pull requests' hover card (Leo 2026-10-19, Claude desktop's session sidebar): hovering a
/// row's pull request badge (`SidebarPullRequestBadgeView`, `sidebar.sessionTree`) lists the
/// pull requests its sessions opened or work on, newest first, one line each: the title, a state
/// pill, `owner/repo #N` and the lines added and removed. A click opens the pull request in a
/// browser tab of the focused pane. It scrolls past ``SidebarPullRequestCardView/visibleRows``.
/// `sidebar.pullRequestCard` (Debug Settings, on by default) turns it off.
///
/// It shows in the app's one hover card window as an owned card (`HoverCardCoordinator.presentOwned`),
/// as the update card's highlights do: it takes clicks and scrolls, a workspace card that shows
/// morphs into it, and a row the pointer reaches next takes the card back. Its only hook into a
/// row is the badge view, which calls ``badgeEntered(_:items:cards:open:)`` and ``badgeExited()``;
/// the workspace hover card leaves the badge to it (`WorkspaceHoverCardController.hoverCardHit`).
@MainActor
final class SidebarPullRequestCardController {
    static let shared = SidebarPullRequestCardController()

    /// The card in the app's one hover card window.
    static let cardID = HoverTargetID("sidebar:pull-requests")

    /// How long the card stays after the pointer leaves the badge or the card, so it can cross
    /// the gap between them.
    static let grace: Duration = .milliseconds(250)

    private let host = SidebarPopoverIslandHost(width: SidebarPullRequestCardView.width)
    private let content = SidebarPullRequestCardView()
    private let closer = DemandTimer(owner: "sidebar.pull-request-card.close")
    private weak var badge: SidebarPullRequestBadgeView?
    private weak var cards: HoverCardCoordinator?
    private var open: ((URL) -> Void)?

    init() {
        content.onOpen = { [weak self] item in self?.activate(item) }
        content.frame = host.bounds
        content.autoresizingMask = [.width, .height]
        host.addSubview(content)
        host.onPointerExit = { [weak self] in self?.scheduleClose() }
        host.onPointerEnter = { [weak self] in self?.closer.cancel() }
    }

    /// The card is on screen (or opening).
    var isPresented: Bool { cards?.isShowingOwned(Self.cardID) ?? false }

    /// The card shows `badge`'s pull requests now.
    func isShowing(for badge: SidebarPullRequestBadgeView) -> Bool { isPresented && self.badge === badge }

    /// The pointer reached `badge`: shows `items` beside it in `cards`' window; `open` opens a
    /// clicked one.
    func badgeEntered(_ badge: SidebarPullRequestBadgeView, items: [SidebarPullRequestItem], cards: HoverCardCoordinator,
                      open: @escaping (URL) -> Void) {
        guard Self.isEnabled, !items.isEmpty, let window = badge.window else { return }
        closer.cancel()
        self.badge = badge
        self.cards = cards
        self.open = open
        content.configure(items)
        host.fit(height: content.preferredHeight)
        let body = HoverCardBody(view: host, placement: .beside, themeAnchor: badge) { [weak self] in self?.content.applyColors() }
        cards.presentOwned(Self.cardID, body: body, anchor: Self.screenFrame(of: badge, in: window), parent: window,
                           interactive: true) { [weak self] in self?.ended() }
        content.applyColors()
    }

    /// The pointer left the badge: the card closes unless it reaches the card in time.
    func badgeExited() {
        scheduleClose()
    }

    func dismiss() {
        closer.cancel()
        open = nil
        cards?.endOwned(Self.cardID)
    }

    /// `sidebar.pullRequestCard`.
    static var isEnabled: Bool { SidebarTunables.pullRequestCard.value }

    /// The card left the window: closed by ``dismiss()``, or taken by a workspace or tab card.
    private func ended() {
        closer.cancel()
        open = nil
    }

    private func scheduleClose() {
        closer.schedule(after: Self.grace) { @MainActor [weak self] in self?.closeUnlessPointed() }
    }

    private func closeUnlessPointed() {
        let pointer = NSEvent.mouseLocation
        if let frame = cards?.ownedCardFrame(Self.cardID), frame.contains(pointer) { return }
        if let badge, let window = badge.window, !badge.isHidden, Self.screenFrame(of: badge, in: window).contains(pointer) { return }
        dismiss()
    }

    private func activate(_ item: SidebarPullRequestItem) {
        guard item.isOpenable(), let url = URL(string: item.url) else { return }
        let open = open
        dismiss()
        open?(url)
    }

    private static func screenFrame(of view: NSView, in window: NSWindow) -> CGRect {
        window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

/// The card's content: one ``SidebarPullRequestCardRow`` per pull request in a scroll view that
/// shows ``visibleRows`` at most.
final class SidebarPullRequestCardView: NSView, HoverCardTextReporting {
    static let width: CGFloat = 440
    /// The most lines shown before the list scrolls.
    static let visibleRows = 8

    var onOpen: ((SidebarPullRequestItem) -> Void)?
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private(set) var rows: [SidebarPullRequestCardRow] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = list
        SystemScrollers.follow(scroll)
        addSubview(scroll)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(Strings.pullRequestCardTitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ items: [SidebarPullRequestItem]) {
        while rows.count < items.count {
            let row = SidebarPullRequestCardRow()
            row.onClick = { [weak self, weak row] in
                guard let self, let item = row?.item else { return }
                self.onOpen?(item)
            }
            rows.append(row)
            list.addSubview(row)
        }
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= items.count
            if index < items.count { row.configure(items[index]) }
        }
        needsLayout = true
    }

    var shownCount: Int { rows.lazy.filter { !$0.isHidden }.count }

    /// Tall enough for every line up to ``visibleRows``.
    var preferredHeight: CGFloat {
        CGFloat(min(shownCount, Self.visibleRows)) * SidebarPullRequestCardRow.height + 2 * Metrics.space1
    }

    var reportedLines: [String] { rows.filter { !$0.isHidden }.map(\.reportedLine) }

    func applyColors() {
        performWithTheme { rows.forEach { $0.applyColors() } }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 0, dy: Metrics.space1)
        let height = SidebarPullRequestCardRow.height
        let shown = rows.filter { !$0.isHidden }
        list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: CGFloat(shown.count) * height)
        for (index, row) in shown.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * height, width: list.bounds.width, height: height)
        }
    }

    /// Top-down rows.
    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}

/// One pull request in the card: title, state pill, `owner/repo #N`, `+adds −dels`. Highlights
/// under the pointer; a click opens it.
final class SidebarPullRequestCardRow: NSView {
    static var height: CGFloat { ceil(SidebarStyle.titleFont.boundingRectForFont.height) + 2 * Metrics.space2 }

    var onClick: (() -> Void)?
    private(set) var item: SidebarPullRequestItem?
    private let title = ChromeLabel(font: SidebarStyle.titleFont)
    private let pill = NSView()
    private let pillLabel = ChromeLabel(font: SidebarStyle.badgeFont)
    private let place = ChromeLabel(font: SidebarStyle.subtitleFont)
    private let additions = ChromeLabel(font: SidebarStyle.badgeFont)
    private let deletions = ChromeLabel(font: SidebarStyle.badgeFont)
    private var hovered = false { didSet { if hovered != oldValue { applyColors() } } }
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Metrics.space1
        pill.wantsLayer = true
        pill.addSubview(pillLabel)
        [title, pill, place, additions, deletions].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: SidebarPullRequestItem) {
        self.item = item
        title.stringValue = item.title.isEmpty ? "#\(item.number)" : item.title
        pillLabel.stringValue = Strings.pullRequestState(item.state)
        place.stringValue = item.repository.isEmpty ? "#\(item.number)" : "\(item.repository) #\(item.number)"
        additions.stringValue = "+\(item.additions)"
        deletions.stringValue = "\u{2212}\(item.deletions)"
        setAccessibilityLabel(Strings.pullRequestCardRow(item))
        applyColors()
        needsLayout = true
    }

    /// The line as the card reports it (`debug.hover_cards`).
    var reportedLine: String {
        [title.stringValue, pillLabel.stringValue, place.stringValue, additions.stringValue, deletions.stringValue].joined(separator: " ")
    }

    /// The pill's color for each state, from the theme, as the row badge colors them.
    static func color(_ state: SidebarPullRequestItem.State) -> NSColor {
        switch state {
        case .conflict, .draft: Palette.attention
        case .failing: Palette.danger
        case .passing: Palette.success
        case .merged: GroupColor.purple.markColor
        case .closed: Palette.textTertiary
        }
    }

    func applyColors() {
        performWithTheme {
            layer?.backgroundColor = hovered ? Palette.hoverFill.cgColor : NSColor.clear.cgColor
            title.textColor = Palette.textPrimary
            place.textColor = Palette.textSecondary
            additions.textColor = Palette.success
            deletions.textColor = Palette.danger
            guard let item else { return }
            let color = Self.color(item.state)
            pillLabel.textColor = color
            pill.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        }
    }

    override func layout() {
        super.layout()
        let inset = Metrics.space2, gap = Metrics.space2, cy = bounds.midY
        func size(_ label: ChromeLabel) -> NSSize { label.naturalSize }
        // Right to left: deletions, additions, place, pill; the title takes what is left.
        var trailing = bounds.width - inset
        for label in [deletions, additions] {
            let s = size(label)
            label.frame = NSRect(x: trailing - ceil(s.width), y: cy - s.height / 2, width: ceil(s.width), height: ceil(s.height))
            trailing = label.frame.minX - Metrics.space1
        }
        trailing -= gap - Metrics.space1
        let placeSize = size(place)
        let placeWidth = min(ceil(placeSize.width), bounds.width * 0.3)
        place.frame = NSRect(x: trailing - placeWidth, y: cy - placeSize.height / 2, width: placeWidth, height: ceil(placeSize.height))
        trailing = place.frame.minX - gap
        let label = size(pillLabel), padX = Metrics.space2, padY = Metrics.space1 / 2
        let pillSize = NSSize(width: ceil(label.width) + 2 * padX, height: ceil(label.height) + 2 * padY)
        pill.frame = NSRect(x: trailing - pillSize.width, y: cy - pillSize.height / 2, width: pillSize.width, height: pillSize.height)
        pill.layer?.cornerRadius = Metrics.chipCornerRadius(height: pillSize.height)
        pillLabel.frame = NSRect(x: padX, y: padY, width: ceil(label.width), height: ceil(label.height))
        trailing = pill.frame.minX - gap
        let titleSize = size(title)
        title.frame = NSRect(x: inset, y: cy - titleSize.height / 2, width: max(0, trailing - inset), height: ceil(titleSize.height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
