public import CmuxNextDaemon
public import CmuxNextDaemonService

/// How one close gesture over several screens or workspaces of one daemon
/// reaches it (Lawrence 2026-10-23: "if i close a bunch of tabs then cmd shift
/// t, it needs to bring all of them back. same for workspaces, panes,
/// everything"): the objects that have a public id and a tab close in ONE
/// `layout.bulk` request (`layout-bulk-v1`), which the daemon stores as one
/// closed group, so one Reopen Closed (Cmd-Shift-T) brings all of them back;
/// the rest (an empty workspace, which `layout.bulk` leaves open; any object
/// on an older daemon) close one by one, each its own group.
public struct BulkClosePlan<Object> {
    /// The objects of the one bulk request, with their public ids.
    public var bulk: [(object: Object, id: ResourceID)]
    /// The objects that close one by one.
    public var each: [Object]

    /// Splits `objects` of one daemon. `servesBulk`: the daemon serves
    /// `layout.bulk` and state resources. A bulk request needs two objects or
    /// more; one alone keeps its own close.
    public init(_ objects: [Object], servesBulk: Bool, id: (Object) -> ResourceID?, hasTabs: (Object) -> Bool) {
        let candidates = servesBulk ? objects.compactMap { object in hasTabs(object) ? id(object).map { (object, $0) } : nil } : []
        guard candidates.count > 1 else {
            bulk = []
            each = objects
            return
        }
        let ids = Set(candidates.map(\.1))
        bulk = candidates
        each = objects.filter { object in id(object).map { !ids.contains($0) } ?? true }
    }
}

@MainActor
extension DaemonService {
    /// Whether this daemon takes a close gesture over several screens or
    /// workspaces as one `layout.bulk` request (`BulkClosePlan`).
    public var servesBulkClose: Bool {
        store.servesStateResources && supports(DaemonCapability.layoutBulk.rawValue)
    }
}

@MainActor
extension WorkspaceClose {
    /// The one close path for several workspaces at once (every bulk close, Close Workspaces in
    /// Group): on each daemon, the workspaces with tabs close in one `layout.bulk` request with
    /// their terminals (`BulkClosePlan`), one closed group, so one Reopen Closed brings all of them
    /// back; an empty workspace, or any on an older daemon, closes alone. `send` runs each daemon
    /// command (the sidebar's resyncs its rows when one fails).
    public static func close(_ members: [(WorkspaceModel, DaemonService)],
                      send: (DaemonService, String, @escaping DaemonCommandBody) -> Void = { $0.send($1, $2) }) {
        var daemons: [DaemonService] = []
        for (_, daemon) in members where !daemons.contains(where: { $0 === daemon }) { daemons.append(daemon) }
        for daemon in daemons {
            let workspaces = members.filter { $0.1 === daemon && $0.0.key != nil }.map(\.0)
            let plan = BulkClosePlan(workspaces, servesBulk: daemon.servesBulkClose, id: \.resourceID,
                                     hasTabs: { $0.screens.contains { $0.panes.contains { !$0.tabs.isEmpty } } })
            if !plan.bulk.isEmpty {
                for (workspace, _) in plan.bulk { _ = WorkspaceClose.closing(workspace, on: daemon) }
                let ids = plan.bulk.map(\.id), keys = plan.bulk.compactMap(\.object.key), bound = daemon.closeReplyBound
                send(daemon, "close-workspaces") { connection in
                    do {
                        try await connection.state.closeBulk(.workspace, ids: ids, endTerminals: true, within: bound)
                    } catch DaemonError.timedOut(_) {
                        try await WorkspaceClose.unanswered(keys, on: daemon, connection: connection) // the store decides past the bound
                    }
                }
            }
            for workspace in plan.each {
                guard let key = workspace.key else { continue }
                let terminals = WorkspaceClose.closing(workspace, on: daemon)
                send(daemon, "close-workspace") { try await WorkspaceClose.close(key, terminals: terminals, on: $0, awaitingReplyOn: daemon) }
            }
        }
    }
}

/// The closed items of one close, for its Undo: the new workspace items
/// (newest first) whose members carry the closing workspaces' names, each
/// name taken once (one bulk close is one item of several members,
/// `BulkClosePlan`; an older daemon stores one item per workspace), the
/// names no item took yet, and the group's own record.
public struct ClosedItemMatch: Sendable {
    public var workspaces: [String] = []
    public var missing: [String]
    public var group: String?

    public init(names: [String], group id: String?, fresh: [ClosedItem]) {
        missing = names
        for item in fresh where item.kind == .workspace && item.group == nil {
            let carried = item.memberNames.isEmpty ? [item.name] : item.memberNames
            var took = false
            for name in carried {
                guard let index = missing.firstIndex(of: name ?? "") else { continue }
                missing.remove(at: index)
                took = true
            }
            if took { workspaces.append(item.id) }
        }
        group = id.flatMap { id in fresh.first { $0.group?.id == id }?.id }
    }
}
