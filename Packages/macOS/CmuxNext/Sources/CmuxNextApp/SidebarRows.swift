import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar

/// The one writer of a window's sidebar rows (cx-odqn): the live rows (the
/// store's, with the saved seed) with the pending drag edits applied in
/// order. An edit shows at once and leaves when its commands replied and
/// the home store holds their result (read-your-writes), or when they
/// failed, so no live recompute in between (a row's title or activity, the
/// echo of one step of a several-step placement) shows the old or a
/// partial order. A helper beside SidebarBridge (its type is at its size limit).
@MainActor
final class SidebarRows {
    private let model: SidebarModel
    private var live: [SidebarRowSection] = []
    private var pending = SidebarPendingEdits()
    /// A group's fold the user asked for that the home store has not shown
    /// yet (cx-qno.17): the newest click wins over a live recompute, so a
    /// fast run of clicks toggles once per click.
    private var folds: [GroupID: (collapsed: Bool, serial: Int)] = [:]
    private var foldSerial = 0

    init(model: SidebarModel) {
        self.model = model
    }

    /// The layout the sidebar draws: the store's with the Chats setting.
    static func visibleLayout(_ document: SidebarLayoutDocument) -> SidebarLayoutDocument {
        document.chatsLayout(enabled: DesignSettings.shared.sidebarSections.showChats)
    }

    /// Shows `live` (when given) with the pending edits applied.
    func show(_ live: [SidebarRowSection]? = nil) {
        if let live { self.live = live }
        var sections = pending.apply(to: self.live)
        for (group, fold) in folds {
            guard let (s, n) = SidebarEdits.locateGroup(group, in: sections),
                  case var .group(shown) = sections[s].nodes[n], shown.isCollapsed != fold.collapsed else { continue }
            shown.isCollapsed = fold.collapsed
            sections[s].nodes[n] = .group(shown)
        }
        model.setSections(sections)
    }

    /// Folds or opens `group` at once and keeps that look until `body`
    /// replied and the home store holds it, or failed (then `resync`).
    func fold(_ group: GroupID, collapsed: Bool, on home: DaemonService, resync: @escaping @MainActor () -> Void,
              _ body: @escaping @Sendable (DaemonConnection) async throws -> Void) {
        foldSerial += 1
        let serial = foldSerial
        folds[group] = (collapsed, serial)
        show()
        let settle: @MainActor () -> Void = { [weak self] in
            guard let self, folds[group]?.serial == serial else { return }
            folds[group] = nil
            show()
        }
        let transaction = ClientTransactionID.generate()
        // task-owner: one personal fold command; settles its fold
        Task {
            guard await home.request("update-personal-group", transaction: transaction, { connection, _ in try await body(connection) }) != nil else {
                settle()
                return resync()
            }
            home.whenApplied(transaction, settle)
        }
    }

    /// Shows `intent` at once, until `settle`.
    func add(_ intent: SidebarIntent) -> SidebarPendingEdits.Token {
        let edit = pending.add(intent)
        show()
        return edit
    }

    func settle(_ edit: SidebarPendingEdits.Token?) {
        guard let edit else { return }
        pending.settle(edit)
        show()
    }

    /// A command's outcome for `edit`: `failed` settles it and runs `resync`;
    /// `applied` settles it (run once the home store holds the command's result).
    func outcome(_ edit: SidebarPendingEdits.Token?, resync: @escaping @MainActor () -> Void)
        -> (failed: @MainActor () -> Void, applied: (@MainActor () -> Void)?) {
        let failed: @MainActor () -> Void = { [weak self] in
            self?.settle(edit)
            resync()
        }
        guard let edit else { return (failed, nil) }
        return (failed, { [weak self] in self?.settle(edit) })
    }

    /// Sends one personal-state command to `home` for `edit`.
    func send(_ label: String, edit: SidebarPendingEdits.Token?, on home: DaemonService, resync: @escaping @MainActor () -> Void,
              _ body: @escaping @Sendable (DaemonConnection) async throws -> Void) {
        let (failed, applied) = outcome(edit, resync: resync)
        let transaction = ClientTransactionID.generate()
        // task-owner: one personal command; settles its edit
        Task {
            guard await home.request(label, transaction: transaction, { connection, _ in try await body(connection) }) != nil else { return failed() }
            if let applied { home.whenApplied(transaction, applied) }
        }
    }
}
