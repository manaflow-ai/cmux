import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import Observation

/// The notifications panel (`showNotifications`, ⌘I): the daemon's
/// notification ledger, newest first, at the top right of the active
/// window. A row opens its tab; its menu and the keyboard run the
/// `notification*` actions with the row's id, the same handlers the palette
/// and the CLI run on the latest unread notification. It reloads on open and whenever a notification
/// arrives or is read while it is shown.
final class NotificationsPanelController {
    /// The argument naming a ledger row (`list-notifications` id).
    static let argument = "notification"

    private let context: AppActionContext
    private var panel: NotificationsPanel?
    private let card = NotificationsPanelView()
    private(set) var rows: [NotificationsPanelRow] = []
    /// Whether the open panel has its first ledger reply.
    private var loaded = false
    private var selection = NotificationsPanelSelection()
    private var watch: Task<Void, Never>?
    /// Bumped per reload, so a slow reply never replaces a newer one.
    private var generation = 0

    init(context: AppActionContext) {
        self.context = context
        card.onMarkAllRead = { [weak self] in self?.perform("markAllNotificationsRead", nil) }
        card.onClearAll = { [weak self] in self?.perform("clearAllNotifications", nil) }
    }

    var isShown: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isShown { close() } else { show() }
    }

    /// The row an invocation names; nil when it names none. A row the
    /// panel no longer lists is refused rather than read as "latest unread".
    func row(_ invocation: ActionInvocation) throws -> NotificationsPanelRow? {
        guard let id = invocation[Self.argument]?.stringValue else { return nil }
        guard let row = rows.first(where: { $0.id == id }) else { throw ActionFailure(message: NotificationsPanelStrings.notificationGone) }
        return row
    }

    // MARK: Showing

    private func show() {
        guard let window = context.services.windows.active?.window else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        selection = NotificationsPanelSelection()
        loaded = false
        render()
        // The panel draws in the window's theme scope, like the window under it.
        window.themeScope.adopt(panel)
        place(panel, in: window)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.onResignKey = { [weak self] in self?.close(restoringKey: false) }
        panel.onKeyElsewhere = { [weak self] in self?.close(restoringKey: false) }
        panel.orderFront(nil)
        panel.makeKey()
        panel.makeFirstResponder(card)
        reload()
        startWatching()
    }

    /// Closes the panel. Esc and the row verbs give the keys back to the
    /// window; losing them to another window does not.
    func close(restoringKey: Bool = true) {
        watch?.cancel()
        watch = nil
        rows = []
        guard let panel, panel.isVisible else { return }
        panel.onResignKey = nil
        if restoringKey, panel.isKeyWindow, let parent = panel.parent, parent.isVisible { parent.makeKey() }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NotificationsPanel {
        let panel = NotificationsPanel()
        panel.contentView = card
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        return panel
    }

    /// Top right of the window's content, under the titlebar.
    private func place(_ panel: NSPanel, in window: NSWindow) {
        let size = card.fittingSize
        let content = window.contentLayoutRect
        let inset = Metrics.space3
        let origin = NSPoint(x: content.maxX - size.width - inset, y: content.maxY - size.height - inset)
        let frame = window.convertToScreen(NSRect(origin: origin, size: size))
        panel.setFrame(frame, display: true)
    }

    // MARK: Rows

    /// Re-reads the ledger while the panel is shown.
    private func startWatching() {
        watch?.cancel()
        let store = context.daemon.store
        // task-owner: NotificationsPanelController.watch, cancelled in close()
        watch = Task { [weak self] in
            var first = true
            for await _ in Observations({ (store.notifications.last?.notification.rawValue ?? 0, NotificationCenterService.unreadCount(store)) }) {
                // The open itself already reloaded.
                if first { first = false; continue }
                self?.reload()
            }
        }
    }

    func reload() {
        guard isShown else { return }
        guard context.daemon.connection != nil else {
            rows = []
            loaded = true
            return render()
        }
        generation += 1
        let generation = generation
        context.daemon.send("list-notifications") { [weak self] connection in
            do {
                let entries = try await connection.notificationLedger()
                await MainActor.run { self?.apply(entries, generation: generation) }
            } catch {
                await MainActor.run { self?.failed(generation: generation) }
                throw error
            }
        }
    }

    private func apply(_ entries: [ListNotificationsRequest.Entry], generation: Int) {
        guard generation == self.generation, isShown else { return }
        let store = context.daemon.store
        let notifications = context.services.notifications
        let fresh = NotificationsPanelRow.make(entries) { notifications.locate(surface: $0, in: store)?.workspace.displayName }
        selection.reconcile(old: rows, new: fresh)
        rows = fresh
        loaded = true
        render()
    }

    /// A ledger read failed (and was logged): the rows shown stay, and a
    /// first read shows the empty state rather than nothing.
    private func failed(generation: Int) {
        guard generation == self.generation, isShown, !loaded else { return }
        loaded = true
        render()
    }

    private func render() {
        let now = Date()
        let views = rows.map { row in
            NotificationRowView(row: row, now: now, callbacks: .init(
                open: { [weak self] in self?.perform("notificationOpen", row) },
                dismiss: { [weak self] in self?.perform("notificationDismiss", row) },
                menu: { [weak self] in self?.menu(for: row) ?? NSMenu() }
            ))
        }
        let height = card.show(views, loaded: loaded)
        card.select(selection.index(in: rows))
        guard let panel, panel.isVisible else { return }
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: NotificationsPanelView.width, height: height), display: true)
    }

    // MARK: Actions

    private func perform(_ id: ActionID, _ row: NotificationsPanelRow?) {
        let arguments: [String: ActionValue] = row.map { [Self.argument: .string($0.id)] } ?? [:]
        context.registry.perform(id, invocation: ActionInvocation(arguments: arguments))
    }

    private func menu(for row: NotificationsPanelRow) -> NSMenu {
        let menu = NSMenu()
        // The rows come from the catalog's `.notification` placements; a
        // read row has nothing to mark.
        let catalog = ContextMenuCatalog.shared
        let ids = catalog.referencedIDs(catalog.entries(for: .notification)).filter { row.unread || $0 != "notificationToggleRead" }
        for id in ids {
            let handler = MenuHandler { [weak self] in self?.perform(id, row) }
            let item = NSMenuItem(title: context.registry.descriptor(for: id)?.title ?? id.rawValue,
                                  action: #selector(MenuHandler.fire), keyEquivalent: "")
            // The item's target is weak; its represented object keeps the handler.
            item.target = handler
            item.representedObject = handler
            menu.addItem(item)
        }
        return menu
    }

    // MARK: Keyboard

    /// Escape closes; Up and Down select; Return opens; Delete dismisses.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        let selected = selection.index(in: rows).map { rows[$0] }
        switch event.keyCode {
        case 53:
            close()
        case 125, 126:
            selection.move(by: event.keyCode == 125 ? 1 : -1, in: rows)
            card.select(selection.index(in: rows))
        case 36, 76:
            guard let selected else { return false }
            perform("notificationOpen", selected)
        case 51, 117:
            guard let selected else { return false }
            perform("notificationDismiss", selected)
        default:
            return false
        }
        return true
    }
}

/// Runs a closure when its menu item is chosen.
private final class MenuHandler: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
        super.init()
    }

    @objc func fire() { run() }
}
