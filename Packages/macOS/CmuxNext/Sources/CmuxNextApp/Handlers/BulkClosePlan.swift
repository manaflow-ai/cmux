import CmuxNextDaemon
import CmuxNextDaemonService

/// How one close gesture over several screens or workspaces of one daemon
/// reaches it (Lawrence 2026-10-23: "if i close a bunch of tabs then cmd shift
/// t, it needs to bring all of them back. same for workspaces, panes,
/// everything"): the objects that have a public id and a tab close in ONE
/// `layout.bulk` request (`layout-bulk-v1`), which the daemon stores as one
/// closed group, so one Reopen Closed (Cmd-Shift-T) brings all of them back;
/// the rest (an empty workspace, which `layout.bulk` leaves open; any object
/// on an older daemon) close one by one, each its own group.
struct BulkClosePlan<Object> {
    /// The objects of the one bulk request, with their public ids.
    var bulk: [(object: Object, id: ResourceID)]
    /// The objects that close one by one.
    var each: [Object]

    /// Splits `objects` of one daemon. `servesBulk`: the daemon serves
    /// `layout.bulk` and state resources. A bulk request needs two objects or
    /// more; one alone keeps its own close.
    init(_ objects: [Object], servesBulk: Bool, id: (Object) -> ResourceID?, hasTabs: (Object) -> Bool) {
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
