import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import QuartzCore

/// The staged update card above the sidebar footer (UPDATE-CARD, Arc-style
/// in cmux's colors): the composer's surface (`CardSurfaceView`, shared by
/// every sidebar card), "Update
/// Ready", the short version and date ("nightly 3845050 · Oct 13", whole at the
/// sidebar's default width), the Automatic Updates switch and one full-width
/// Restart to Update button (one click installs and relaunches; disabled,
/// Installing…, once taken). Hovering the card shows what it leaves out (Leo
/// 2026-10-13): the full build, the highlights and "See all changes", in the
/// themed popup beside it (the React surface, cx-urd.61.2). A small "Hide"
/// button in the top right corner hides this version's card at once until a
/// newer one (UPDATE-CARD-CLOSE, Lawrence 2026-10-14); the right-click menu
/// adds Remind Me in 1 Day / 3 Days / 1 Week. Hidden without a staged update.
final class SidebarUpdateCardView: NSView {
    var onInstall: (() -> Void)?
    var onAutomaticUpdates: ((Bool) -> Void)?
    /// "See all changes" (the button's accessibility action): the What's New page.
    var onOpenChanges: (() -> Void)?
    /// The Hide button or a menu item: the card's id and the action's id.
    var onCloseAction: ((String, String) -> Void)?
    private(set) var card: SidebarUpdateCard?
    /// The composer's surface, under everything else.
    let surface = CardSurfaceView()
    private let titleLabel = ChromeLabel(labelWithString: "")
    /// The short version and build date.
    let detailLabel = ChromeLabel(labelWithString: "")
    let toggle = SidebarUpdateToggle()
    let button = SidebarUpdateButton()
    /// "Hide": one click hides this version's card (``SidebarUpdateCard/closeAction``).
    let closeButton = SidebarCardTextButton()
    /// The staged update's highlights (the React ready surface; set by the sidebar).
    var highlights: (any SidebarSurfaceIsland)? {
        didSet {
            // A new page closes the popup that held the old one.
            cancelNotesClose()
            if notesAreShown { hoverCards()?.endOwned(Self.notesID) }
            oldValue?.onHeightChange = nil
            oldValue?.view.removeFromSuperview()
            highlights?.onAction = { [weak self] in self?.hideNotes() }
            parkHighlights()
        }
    }

    /// Makes ``highlights`` once a card shows: each is a web page, and two
    /// per window built at launch with no update staged cost about 50 ms of
    /// main thread before the first frame.
    var surfaces: (any SidebarUpdateSurfaces)? {
        didSet {
            highlights?.close()
            highlights = card == nil ? nil : surfaces?.island(.ready)
        }
    }

    /// The highlights page waits in the card's view tree, transparent,
    /// click-through and outside the card's bounds, so it loads and reports
    /// its height while the card shows; the popover takes it while open and
    /// gives it back when it closes.
    func parkHighlights() {
        guard let highlights, highlights.view.superview !== parking else { return }
        if parking.superview == nil { addSubview(parking, positioned: .below, relativeTo: nil) }
        parking.frame = NSRect(x: SidebarIslandParking.offscreenX, y: 0, width: Self.popoverWidth, height: max(1, highlights.contentHeight))
        highlights.view.removeFromSuperview()
        highlights.view.frame = parking.bounds
        highlights.view.autoresizingMask = [.width, .height]
        parking.addSubview(highlights.view)
    }
    /// The highlights page's host in the app's one hover card (menu-wide, page-tall).
    let notesHost = SidebarPopoverIslandHost(width: SidebarUpdateCardView.popoverWidth)
    /// The app's one hover card coordinator (the sidebar's list's); the popup shows in its window.
    var hoverCards: @MainActor () -> HoverCardCoordinator? = { nil }
    /// The highlights page's place while the popover is closed.
    let parking = SidebarIslandParking()
    /// Set by the hover owner (`PointerHover`, cx-3wu5).
    private(set) var isHovered = false
    private var pointerHover: PointerHover?
    /// The card's own move tracking: every move over the card asks the hover owner again, so the
    /// whole card opens the popup even when no enter reached it (a still pointer the card
    /// appeared under, an enter that a child window covering the card at that moment took).
    private var moveTracking: NSTrackingArea?
    /// The mouse went down on the card's body (not one of its controls).
    private var clickStartedOnCard = false
    /// The popup's delayed close after the pointer left the card or the popup
    /// (``scheduleNotesClose()``): one-shot, re-armed while the pointer is on its way.
    /// Tests swap in one on a manual clock.
    var notesCloseTimer = DemandTimer(owner: "sidebar.update-card.notes-close")
    /// How long the pending close has already waited (capped at ``notesCorridorLimit``).
    var notesCloseWaited: Duration = .zero
    /// How many close checks ran (tests wait on it instead of a fixed number of yields).
    var notesCloseChecks = 0
    /// The popup closed while the pointer was still on the card (Hide, an
    /// action, the app resigning active): moves over the card do not reopen it
    /// until the pointer leaves and comes back.
    var notesDismissedWhileHovered = false
    /// A click on the card pinned the preview open (Leo 2026-10-20: hover previews, a click
    /// expands it to read and scroll): the pointer leaving no longer closes it, and it grows
    /// to ``SidebarUpdateCardView/pinnedMaxHeightFraction`` of the window. Another click on the
    /// card, Hide, an action in it or another hover card taking the window unpins it.
    var notesPinned = false
    /// The pointer on screen, read by every popup check (tests place it).
    var screenPointer: () -> CGPoint = { NSEvent.mouseLocation }
    /// Shows and hides the card with its entrance and exit (``SidebarCardTransition``).
    private(set) lazy var presence = SidebarCardPresence(self, policy: motionPolicy)
    /// The motion settings the card's transitions follow (`Motion.policy`; tests set their own before the first card).
    var motionPolicy: @MainActor () -> MotionPolicy = { Motion.overlays.policy }
    /// The card plays its exit: the slot keeps it in place until it has gone.
    var isLeaving: Bool { presence.isLeaving }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(surface)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        [titleLabel, detailLabel, toggle, button, closeButton].forEach(addSubview)
        toggle.setAccessibilityIdentifier("cmux.sidebar.update.automatic")
        button.setAccessibilityIdentifier("cmux.sidebar.update.install")
        closeButton.setAccessibilityIdentifier("cmux.sidebar.update.hide")
        button.onPress = { [weak self] in self?.onInstall?() }
        closeButton.onPress = { [weak self] in self?.closePressed() }
        toggle.onToggle = { [weak self] on in self?.onAutomaticUpdates?(on) }
        setAccessibilityElement(false)
        isHidden = true
        pointerHover = PointerHover(self) { [weak self] hovering in self?.setHovered(hovering) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Shows `card`, or hides the view (and its popover) for nil. The
    /// highlights page is made when a card first shows, so it has loaded
    /// and measured before the first hover, and closed when the card goes.
    func configure(_ card: SidebarUpdateCard?) {
        guard card != self.card else { return }
        let previous = self.card, wasShowing = !isHidden && !isLeaving
        self.card = card
        presence.setShown(card != nil)
        guard let card else {
            // The card went away: its page goes too (a web page per window
            // kept loaded with no staged update, cx-asynu).
            hideNotes()
            highlights?.close()
            highlights = nil
            return
        }
        if highlights == nil { highlights = surfaces?.island(.ready) }
        // Restart to Update becoming Installing… crossfades instead of popping.
        if let previous, wasShowing, previous.title != card.title || previous.detail != card.detail
            || previous.buttonTitle != card.buttonTitle || previous.isEnabled != card.isEnabled {
            presence.transition.crossfade(layer)
        }
        titleLabel.stringValue = card.title
        detailLabel.stringValue = card.detail ?? ""
        detailLabel.isHidden = card.detail == nil
        closeButton.isHidden = card.closeTitle == nil || card.closeAction == nil
        closeButton.configure(title: card.closeTitle ?? "", help: card.closeLabel)
        toggle.configure(title: card.automaticUpdatesTitle, isOn: card.automaticUpdates, animated: wasShowing)
        button.configure(title: card.buttonTitle, enabled: card.isEnabled,
                         help: [card.notes.headline, card.notes.keepsRunning].joined(separator: " "))
        // The popup with "See all changes" opens on hover only: VoiceOver reaches it here.
        button.setAccessibilityCustomActions(card.seeAllTitle.map { title in
            [NSAccessibilityCustomAction(name: title) { [weak self] in
                self?.onOpenChanges?()
                return true
            }]
        } ?? [])
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Geometry

    /// Compact (Leo 2026-10-19): a 10 pt inset, the detail right under the
    /// title, and 8 pt between the rows.
    private static var padding: CGFloat { Metrics.space2 + Metrics.space1 / 2 }
    private static var titleFont: NSFont { Typography.bodyEmphasized }

    private static var captionHeight: CGFloat { ceil(Typography.caption.boundingRectForFont.height) }

    /// The card's height for `card`: padding, title, the detail line when
    /// present, the switch row, the button, padding.
    static func height(for card: SidebarUpdateCard) -> CGFloat {
        let title = ceil(titleFont.boundingRectForFont.height)
        let detail = card.detail == nil ? 0 : Metrics.space1 / 2 + captionHeight
        return ceil(padding + title + detail + Metrics.space2
            + SidebarUpdateToggle.height + Metrics.space2 + SidebarUpdateButton.height + padding)
    }

    override func layout() {
        super.layout()
        let b = bounds, pad = Self.padding
        surface.frame = b
        surface.cornerRadius = Metrics.space3
        titleLabel.font = Self.titleFont
        let width = max(0, b.width - 2 * pad)
        let th = ceil(Self.titleFont.boundingRectForFont.height)
        let closeWidth = closeButton.fittingWidth, closeHeight = SidebarCardTextButton.height
        let closeRoom = closeButton.isHidden ? 0 : closeWidth + Metrics.space1
        closeButton.frame = NSRect(x: b.width - pad / 2 - closeWidth, y: pad + (th - closeHeight) / 2, width: closeWidth, height: closeHeight)
        titleLabel.frame = NSRect(x: pad, y: pad, width: max(0, width - closeRoom), height: th)
        var y = titleLabel.frame.maxY
        let caption = Self.captionHeight
        if !detailLabel.isHidden {
            y += Metrics.space1 / 2
            detailLabel.font = Typography.caption
            detailLabel.frame = NSRect(x: pad, y: y, width: width, height: caption)
            y += caption
        }
        toggle.frame = NSRect(x: pad, y: y + Metrics.space2, width: width, height: SidebarUpdateToggle.height)
        button.frame = NSRect(x: pad, y: toggle.frame.maxY + Metrics.space2, width: width, height: SidebarUpdateButton.height)
        presence.didLayout()
    }

    override func updateLayer() {
        performWithTheme {
            titleLabel.textColor = Palette.textPrimary
            // The version line is quiet: the card's title and its action carry it.
            detailLabel.textColor = Palette.textTertiary
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { hideNotes() }
    }

    // MARK: Close

    /// The card's right-click menu (hide, remind me later); nil while installing.
    var closeMenu: NSMenu? {
        guard let card, card.closeTitle != nil, !card.closeMenu.isEmpty else { return nil }
        let menu = NSMenu()
        for action in card.closeMenu {
            let item = menu.addItem(withTitle: action.title, action: #selector(closeItem(_:)), keyEquivalent: "")
            (item.target, item.representedObject) = (self, action.id)
        }
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? { closeMenu }

    /// Hide: one click hides this version's card (no menu). It fades out; under Reduce Motion it
    /// goes in one frame (Lawrence 2026-10-20).
    private func closePressed() {
        hideNotes()
        presence.hidesNextAtOnce = motionPolicy().reduceMotion
        if let id = card?.id, let action = card?.closeAction { onCloseAction?(id, action) }
    }

    @objc private func closeItem(_ item: NSMenuItem) {
        presence.hidesNextAtOnce = motionPolicy().reduceMotion
        if let id = card?.id, let action = item.representedObject as? String { onCloseAction?(id, action) }
    }

    // MARK: Hover

    /// The pointer came onto the card: the notes show. It left (or the card
    /// moved or hid under it): the popover stays while the pointer went into
    /// it (to click a link), else it closes.
    private func setHovered(_ hovering: Bool) {
        isHovered = hovering
        if hovering { return showNotes() }
        notesDismissedWhileHovered = false
        guard !pointerIsOverNotes() else { return }
        // Not at once: the pointer may be on its way to the popup (``scheduleNotesClose()``).
        scheduleNotesClose()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let moveTracking { removeTrackingArea(moveTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        moveTracking = area
    }

    /// Not passed up the responder chain: the sidebar has nothing to do with it.
    override func mouseMoved(with event: NSEvent) {
        guard !isHovered || !notesAreShown else { return }
        pointerHover?.refresh()
        if isHovered, !notesAreShown, !notesDismissedWhileHovered { showNotes() }
    }

    // MARK: Click

    override func mouseDown(with event: NSEvent) {
        // Control-click is a right click: AppKit's default opens the card's context menu.
        if event.modifierFlags.contains(.control) {
            super.mouseDown(with: event)
            return
        }
        // The card's own body (labels pass their clicks here); its controls take their own.
        clickStartedOnCard = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { clickStartedOnCard = false }
        guard clickStartedOnCard, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        toggleNotesPinned()
    }

    override func viewDidHide() {
        super.viewDidHide()
        hideNotes()
        pointerHover?.refresh()
    }
}
