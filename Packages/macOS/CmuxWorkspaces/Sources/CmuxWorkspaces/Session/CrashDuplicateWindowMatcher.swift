public import Foundation

/// Decides whether two windows in one session snapshot are the same window
/// written twice by a crash. The app builds a `WindowSignature` for each
/// window and merges the pairs this matcher accepts.
public enum CrashDuplicateWindowMatcher {
    public struct WindowSignature: Equatable, Sendable {
        public var windowId: UUID?
        public var workspaceCount: Int
        /// Every workspace's ID, in order, or nil when any workspace has none.
        public var workspaceIDs: [UUID]?
        /// Agent session checkpoints of the window's panels. Shared multiplexer
        /// sessions (tmux, herdr) must not be included: two real windows can
        /// attach the same one.
        public var checkpointIDs: Set<String>
        /// Non-blank custom workspace titles, trimmed.
        public var workspaceTitles: [String]

        public init(
            windowId: UUID?,
            workspaceCount: Int,
            workspaceIDs: [UUID]?,
            checkpointIDs: Set<String>,
            workspaceTitles: [String]
        ) {
            self.windowId = windowId
            self.workspaceCount = workspaceCount
            self.workspaceIDs = workspaceIDs
            self.checkpointIDs = checkpointIDs
            self.workspaceTitles = workspaceTitles
        }
    }

    /// Two windows are one when:
    /// - they share a window ID (or both predate window IDs) and either list
    ///   the same workspace IDs with no checkpoints, or hold the same
    ///   checkpoints with the same workspace count, or, with at least three
    ///   titled workspaces and the same title multiset, share at least 75% of
    ///   the smaller window's checkpoints (a later generation with a few new
    ///   checkpoints);
    /// - or they have different window IDs, the same workspace count and the
    ///   same multiset of at least three titles, and every one of the smaller
    ///   window's checkpoints (at least two) is in the other. One agent
    ///   session runs in one place, so a window whose sessions all live in
    ///   another window is a crash replay of it that was given a new ID.
    public static func isDuplicate(_ lhs: WindowSignature, _ rhs: WindowSignature) -> Bool {
        guard mayShareIdentity(lhs, rhs) else {
            return isReplayWithNewWindowID(lhs, rhs)
        }
        if let lhsIDs = lhs.workspaceIDs, let rhsIDs = rhs.workspaceIDs,
           !lhsIDs.isEmpty, lhsIDs == rhsIDs, lhs.checkpointIDs.isEmpty, rhs.checkpointIDs.isEmpty {
            return true
        }
        guard !lhs.checkpointIDs.isEmpty, !rhs.checkpointIDs.isEmpty else { return false }
        if lhs.checkpointIDs == rhs.checkpointIDs, lhs.workspaceCount == rhs.workspaceCount {
            return true
        }
        // The title rule needs at least three titled workspaces, so a
        // one- or two-workspace window never merges on overlap alone.
        guard lhs.workspaceCount == rhs.workspaceCount,
              hasSameTitleMultiset(lhs, rhs) else { return false }
        let overlap = lhs.checkpointIDs.intersection(rhs.checkpointIDs).count
        let smaller = min(lhs.checkpointIDs.count, rhs.checkpointIDs.count)
        return Double(overlap) / Double(smaller) >= 0.75
    }

    private static func isReplayWithNewWindowID(_ lhs: WindowSignature, _ rhs: WindowSignature) -> Bool {
        guard lhs.workspaceCount == rhs.workspaceCount,
              hasSameTitleMultiset(lhs, rhs) else {
            return false
        }
        let (smaller, larger) = lhs.checkpointIDs.count <= rhs.checkpointIDs.count
            ? (lhs.checkpointIDs, rhs.checkpointIDs)
            : (rhs.checkpointIDs, lhs.checkpointIDs)
        return smaller.count >= 2 && smaller.isSubset(of: larger)
    }

    private static func hasSameTitleMultiset(_ lhs: WindowSignature, _ rhs: WindowSignature) -> Bool {
        lhs.workspaceTitles.count >= max(3, lhs.workspaceCount - 2)
            && lhs.workspaceTitles.count == rhs.workspaceTitles.count
            && lhs.workspaceTitles.sorted() == rhs.workspaceTitles.sorted()
    }

    private static func mayShareIdentity(_ lhs: WindowSignature, _ rhs: WindowSignature) -> Bool {
        switch (lhs.windowId, rhs.windowId) {
        case let (lhsID?, rhsID?): return lhsID == rhsID
        case (nil, nil): return true
        default: return false
        }
    }
}
