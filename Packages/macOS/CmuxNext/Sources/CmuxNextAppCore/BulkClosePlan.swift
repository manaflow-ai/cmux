public import CmuxNextActions
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

    /// Whether this daemon's bulk close also takes workspaces with no tab, ids already gone and tabs that
    /// leave before its commit (`layout-bulk-bare-v1`): one request closes every chosen workspace.
    public var servesBareBulkClose: Bool {
        servesBulkClose && supports(DaemonCapability.layoutBulkBare.rawValue)
    }
}

@MainActor
extension WorkspaceClose {
    /// The one close path for several workspaces at once (every bulk close, Close Workspaces in
    /// Group): on each daemon, the workspaces close in one `layout.bulk` request with their
    /// terminals (`BulkClosePlan`), one closed group, so one Reopen Closed brings all of them back.
    /// A daemon with `layout-bulk-bare-v1` takes the empty ones in that request too; on an older one
    /// an empty workspace (and any workspace of a daemon with no bulk close) closes alone, one
    /// request after another in one command: hundreds sent at once overflowed the daemon's
    /// per-connection request queue (256), which refused them unrun and listed the rows again
    /// (Lawrence 2026-11-05: "they all suddenly came back"). `send` runs each daemon command (the
    /// sidebar's resyncs its rows when one fails).
    public static func close(_ members: [(WorkspaceModel, DaemonService)],
                      send: (DaemonService, String, @escaping DaemonCommandBody) -> Void = { $0.send($1, $2) }) {
        var daemons: [DaemonService] = []
        for (_, daemon) in members where !daemons.contains(where: { $0 === daemon }) { daemons.append(daemon) }
        for daemon in daemons {
            let workspaces = members.filter { $0.1 === daemon && $0.0.key != nil }.map(\.0)
            let bare = daemon.servesBareBulkClose
            let plan = BulkClosePlan(workspaces, servesBulk: daemon.servesBulkClose, id: \.resourceID,
                                     hasTabs: { bare || $0.screens.contains { $0.panes.contains { !$0.tabs.isEmpty } } })
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
            let singles = plan.each.compactMap { workspace in workspace.key.map { ($0, WorkspaceClose.closing(workspace, on: daemon)) } }
            if singles.isEmpty { continue }
            send(daemon, "close-workspace") { connection in
                // One after another: the first refusal is the command's; the others still close.
                var refusal: (any Error)?
                for (key, terminals) in singles {
                    do { try await WorkspaceClose.close(key, terminals: terminals, on: connection, awaitingReplyOn: daemon) } catch {
                        if refusal == nil { refusal = error }
                    }
                }
                if let refusal { throw refusal }
            }
        }
    }

    /// Closes `members`, every one on `daemon`, from a flow that settles each row by its own result
    /// (``WorkspaceSelectionCloseFlow``): one `layout.bulk` request when the daemon serves
    /// `layout-bulk-bare-v1` (its refusal is every member's), else one close per workspace, at most
    /// ``singlesInFlight`` at a time so a large selection never overflows the daemon's request queue.
    /// `close` runs one daemon command and returns its failure (nil: done).
    public static func settleEach(_ members: [(WorkspaceModel, DaemonService)], on daemon: DaemonService,
                                  terminals: [[Terminal]],
                                  close: @escaping @MainActor (String, @escaping DaemonCommandBody) async -> ActionWorkFailure?)
        async -> [ActionWorkFailure?] {
        let ids = members.compactMap(\.0.resourceID), keys = members.compactMap(\.0.key)
        if daemon.servesBareBulkClose, members.count > 1, ids.count == members.count, keys.count == members.count {
            let bound = daemon.closeReplyBound
            let failure = await close("close-workspaces") { connection in
                do {
                    try await connection.state.closeBulk(.workspace, ids: ids, endTerminals: true, within: bound)
                } catch DaemonError.timedOut(_) {
                    try await WorkspaceClose.unanswered(keys, on: daemon, connection: connection) // the store decides past the bound
                }
            }
            return members.map { _ in failure }
        }
        var failures: [ActionWorkFailure?] = Array(repeating: nil, count: members.count)
        var next = 0
        while next < members.count {
            let window = next..<min(next + singlesInFlight, members.count)
            // task-owner: at most `singlesInFlight` closes, all awaited right below.
            let started = window.map { index in
                Task { @MainActor () -> ActionWorkFailure? in
                    guard let key = members[index].0.key else { return nil }
                    let shown = terminals[index]
                    return await close("close-workspace") { try await WorkspaceClose.close(key, terminals: shown, on: $0, awaitingReplyOn: daemon) }
                }
            }
            for (index, task) in zip(window, started) { failures[index] = await task.value }
            next = window.upperBound
        }
        return failures
    }

    /// How many single workspace closes one batch keeps in flight on a daemon without
    /// `layout-bulk-bare-v1`: well under its per-connection request queue (256).
    public static let singlesInFlight = 16
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
