public import AppKit
public import CmuxNextDesign

/// What draws the group editor bubble: the App's React page in a native popup
/// (CmuxNextApp GroupEditorService, webviews/src/pages/group-editor). The
/// sidebar decides when it opens, which group it follows and what its edits
/// do; the surface only shows it and reports what the person did.
@MainActor
public protocol SidebarGroupEditorSurface: AnyObject {
    /// Shows `group`'s editor with `items` at `anchor` over `parent`, in
    /// `themeAnchor`'s theme. `ordersFront` false lays it out off screen (tests,
    /// a hidden window).
    func present(_ group: SidebarGroup, items: [[SidebarGroupEditorItem]], anchor: PopupAnchor, parent: NSWindow,
                 themeAnchor: NSView, ordersFront: Bool, events: SidebarGroupEditorEvents)
    /// The shown group changed (its color, or its name when the field is untouched).
    func refresh(_ group: SidebarGroup)
    /// Closes the bubble; its last typed name commits, then `events.close` runs.
    func dismiss()
}

/// What the person did in the editor, in the order it happened.
@MainActor
public struct SidebarGroupEditorEvents {
    public let rename: (String) -> Void
    public let color: (GroupColor) -> Void
    public let customColor: () -> Void
    public let item: (String) -> Void
    /// The bubble closed, after any rename it committed.
    public let close: () -> Void
}

/// The workspace group editor (cx-rcby, Lawrence 2026-10-08: the Chrome tab
/// group bubble): a name field that opens focused with the name selected,
/// a row of color dots (none, then the group palette) and the group's
/// actions in sections. Opened from the group chip, its more button or a
/// right-click. Every edit goes out through the callbacks; the editor
/// never edits sidebar state.
@MainActor
public final class SidebarGroupEditor {
    var onRename: ((GroupID, String) -> Void)?
    var onColor: ((GroupID, GroupTint) -> Void)?
    var onItem: ((GroupID, String) -> Void)?
    /// The editor closed, after any rename it committed.
    var onClose: ((GroupID) -> Void)?
    /// Draws the bubble; nil (a sidebar with no App) tracks the editor without drawing it.
    weak var surface: SidebarGroupEditorSurface?
    private(set) var shownGroup: GroupID?
    /// The rows the open editor shows.
    private(set) var shownItems: [[SidebarGroupEditorItem]] = []
    /// A member of the shown group: the store may give a group the sidebar
    /// made another id, and the editor follows it.
    private var member: WorkspaceID?
    /// The groups the last update showed (`follow`).
    private var known: Set<GroupID> = []
    /// The group whose editor closed last, the event time it closed at, and
    /// the click it closed during (a mouse-up has its mouse-down's number).
    private var lastClosed: (group: GroupID, time: TimeInterval, click: Int?)?
    /// The shown group's color, where the color panel starts.
    private var shownTint: GroupTint?
    /// Bumped by every show, so a late close from an earlier bubble ends nothing.
    private var generation = 0
    private let colorPanel = GroupColorPanel.shared
    /// Where the open editor opened from, and the window it opened over.
    private(set) var shownAnchor: PopupAnchor?
    private(set) weak var shownParent: NSWindow?

    /// The page's width in CSS pixels at 100% page zoom (webviews/src/pages/group-editor). Its controls are fixed CSS
    /// sizes that scale only by the Interface Size (`Typography.userScale`, its `--cmux-interface-scale`), not by the
    /// density, so the width is this times that, at every density: the eleven dots, their gaps and the insets need about
    /// 234 of it.
    static let pageWidth: CGFloat = 240
    /// The editor's width at 100% page zoom, at the Interface Size.
    public static var width: CGFloat { pageWidth * Typography.userScale }

    /// The card's frame on screen for a card `height` tall opened at `anchor` over `parent`: under the
    /// control that opened it, on the anchor's edge, above it when there is no room below, inside the window.
    /// `zoom` is the page zoom (`app.uiScale`): the editor is `width` wide at 100% and scales with its page.
    public static func cardFrame(anchor: PopupAnchor, parent: NSWindow, height: CGFloat, zoom: CGFloat = 1) -> CGRect {
        anchor.cardFrame(size: CGSize(width: width * zoom, height: height), visible: (parent.screen ?? NSScreen.main)?.visibleFrame,
                         window: parent.convertToScreen(parent.contentLayoutRect))
    }

    /// The open editor's card frame for a card `height` tall (tests and the real-app proof).
    func cardFrame(height: CGFloat) -> CGRect? {
        guard let shownAnchor, let shownParent else { return nil }
        return Self.cardFrame(anchor: shownAnchor, parent: shownParent, height: height)
    }

    public var isVisible: Bool { shownGroup != nil }
    /// False in tests: the bubble is laid out but never put on screen.
    var ordersFront = true

    func show(_ group: SidebarGroup, items: [[SidebarGroupEditorItem]], anchor: PopupAnchor, parent: NSWindow, themeAnchor: NSView) {
        if let shownGroup, shownGroup != group.id { hide() }
        generation += 1
        let shown = generation
        shownGroup = group.id
        shownTint = group.tint
        shownItems = items
        shownAnchor = anchor
        shownParent = parent
        member = group.workspaces.first?.id
        let events = SidebarGroupEditorEvents(
            rename: { [weak self] name in self?.current(shown).map { self?.onRename?($0, name) } },
            color: { [weak self] color in self?.current(shown).map { self?.pick(color, for: $0) } },
            customColor: { [weak self] in
                guard let self, let id = self.current(shown) else { return }
                // The panel takes focus and the bubble closes; the color panel keeps the
                // group, and a new empty group is kept for it (not deleted on close).
                self.onItem?(id, SidebarGroupEditing.keepGroupItem)
                self.colorPanel.open(current: self.shownTint) { [weak self] tint in self?.onColor?(id, tint) }
            },
            item: { [weak self] item in self?.current(shown).map { self?.onItem?($0, item) } },
            close: { [weak self] in self?.closed(shown) }
        )
        // A window off screen (tests, a hidden window) gets no bubble on screen.
        surface?.present(group, items: items, anchor: anchor, parent: parent, themeAnchor: themeAnchor,
                         ordersFront: ordersFront && parent.isVisible, events: events)
    }

    /// The shown group while the bubble of show `generation` is the open one.
    private func current(_ shown: Int) -> GroupID? {
        shown == generation ? shownGroup : nil
    }

    /// A dot was picked. The first dot is spoken "No color" (`GroupEditorStrings.colorName`): it clears the
    /// color, as the menu's ⊘ does, instead of storing a grey band.
    func pick(_ color: GroupColor, for id: GroupID) {
        let tint: GroupTint = color == .grey ? .none : .palette(color)
        shownTint = tint
        onColor?(id, tint)
    }

    private func closed(_ shown: Int) {
        guard let id = current(shown) else { return }
        shownGroup = nil
        shownItems = []
        shownAnchor = nil
        member = nil
        let event = NSApp.currentEvent
        lastClosed = (id, event?.timestamp ?? ProcessInfo.processInfo.systemUptime, Self.clickNumber(event))
        onClose?(id)
    }

    /// Keeps the open editor on its group after a sidebar update: the same
    /// group refreshes its color; a group the store re-identified is found
    /// by its member; a group that is gone closes the editor.
    func follow(_ groups: [GroupID: SidebarGroup]) {
        defer { known = Set(groups.keys) }
        guard let shown = shownGroup else { return }
        if let group = groups[shown] {
            shownTint = group.tint
            surface?.refresh(group)
            if member == nil { member = group.workspaces.first?.id }
            return
        }
        // Only a group that just appeared can be the shown one under a new
        // id; a member dragged into another group ends the editor.
        if let member, let moved = groups.values.first(where: { !known.contains($0.id) && $0.workspaces.contains { $0.id == member } }) {
            shownGroup = moved.id
            surface?.refresh(moved)
            return
        }
        hide()
    }

    /// Whether the editor of `group` closed during the click that is
    /// happening now (the click made the sidebar's window key, which closes
    /// the bubble first): that click toggles it closed, it does not reopen it.
    /// Clicks are matched by their event number, so fast repeated clicks
    /// toggle open, closed, open (cx-q5jw); a close outside a click falls
    /// back to the double-click time.
    func closedByThisClick(_ group: GroupID, event: NSEvent?) -> Bool {
        guard let closed = lastClosed, closed.group == group, let event else { return false }
        if let click = Self.clickNumber(event), let closedClick = closed.click { return click == closedClick }
        return event.timestamp - closed.time <= NSEvent.doubleClickInterval
    }

    private static func clickNumber(_ event: NSEvent?) -> Int? {
        switch event?.type {
        case .leftMouseDown?, .leftMouseUp?: event?.eventNumber
        default: nil
        }
    }

    /// Closes the editor. With no surface it ends here; a surface's dismiss
    /// commits the typed name and reports the close.
    func hide() {
        guard isVisible else { return }
        guard let surface else { return closed(generation) }
        surface.dismiss()
    }
}
