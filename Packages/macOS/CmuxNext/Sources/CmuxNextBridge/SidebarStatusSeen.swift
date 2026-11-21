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

    /// Marks the current row's error and success reports as seen, the symbols that
    /// report something finished. Live states (working, busy, paused, waiting on the
    /// person) stay drawn: seeing them does not end them. A changed report remains
    /// visible because its state, label, source, or update time changes its identity.
    /// The kept set is the current one, so reports that went away are forgotten.
    @discardableResult
    public func markSeen(_ reports: [StatusReport], workspaceID: String) -> Bool {
        let current = Set(reports.filter { Self.clearsWhenSeen($0.state) })
        let old = seen[workspaceID, default: []]
        guard current != old else { return false }
        if current.isEmpty { seen[workspaceID] = nil } else { seen[workspaceID] = current }
        // Forgetting reports that went away hides nothing new: no row needs to redraw.
        guard !current.isSubset(of: old) else { return false }
        revisions[workspaceID] = (revisions[workspaceID] ?? 0) &+ 1
        return true
    }

    /// Whether a look at the row ends the symbol, as it reads the blue dot.
    public static func clearsWhenSeen(_ state: StatusIndicatorState) -> Bool {
        switch state {
        case .error, .success: true
        default: false
        }
    }
}
