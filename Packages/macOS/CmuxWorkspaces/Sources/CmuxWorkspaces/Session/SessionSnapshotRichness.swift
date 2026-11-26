public import Foundation

/// How much restorable layout a session snapshot carries.
///
/// Used to decide whether a new snapshot may replace an older one on disk and
/// which history entries to keep. Panels count first because a lost agent
/// terminal costs more than a lost empty workspace; workspaces break ties.
public struct SessionSnapshotRichness: Comparable, Hashable, Sendable {
    public var workspaces: Int
    public var panels: Int

    public init(workspaces: Int, panels: Int) {
        self.workspaces = max(0, workspaces)
        self.panels = max(0, panels)
    }

    public static let empty = SessionSnapshotRichness(workspaces: 0, panels: 0)

    public static func < (lhs: SessionSnapshotRichness, rhs: SessionSnapshotRichness) -> Bool {
        if lhs.panels != rhs.panels { return lhs.panels < rhs.panels }
        return lhs.workspaces < rhs.workspaces
    }
}
