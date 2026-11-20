import CmuxNextCompat
public import CmuxNextDesign
import Observation

/// Client-side view state for status symbols that belong to a workspace row.
/// The daemon keeps the report until its owner replaces or clears it. A row
/// symbol is still useful only until the person enters that workspace, so the
/// app remembers the report that was seen and filters that same report on every
/// sidebar layout, including a collapsed or narrow one.
@MainActor @Observable
public final class SidebarStatusSeenStore {
    private var seen: [String: Set<StatusReport>] = [:]
    /// One revision per workspace keeps a look at one row from waking every row.
    private let revisions = ObservedMap<String, UInt64>()

    public init() {}

    /// Reports whose exact state has not been seen in `workspace`.
    public func visible(_ reports: [StatusReport], workspaceID: String?) -> [StatusReport] {
        guard let workspaceID else { return reports }
        _ = revisions[workspaceID]
        let seen = seen[workspaceID, default: []]
        return reports.filter { !seen.contains($0) }
    }

    /// Marks all current row reports as seen. A changed report remains visible
    /// because its state, label, source, or update time changes its identity.
    @discardableResult
    public func markSeen(_ reports: [StatusReport], workspaceID: String) -> Bool {
        let current = Set(reports.filter { $0.state.isVisible })
        guard !current.isEmpty else { return false }
        let old = seen[workspaceID, default: []]
        let next = old.union(current)
        guard next != old else { return false }
        seen[workspaceID] = next
        revisions[workspaceID] = (revisions[workspaceID] ?? 0) &+ 1
        return true
    }

    /// Marks every source that contributes a workspace row through one path.
    @discardableResult
    public func markSeen(tabs: [TabModel], status: WorkspaceStatus?, workspaceID: String) -> Bool {
        let reports = tabs.flatMap(StatusMapping.shared.reports) + StatusMapping.shared.reports(status)
        return markSeen(reports, workspaceID: workspaceID)
    }
}
