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
        /// Agent session IDs and resume checkpoint IDs of the window's panels.
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

    public static func isDuplicate(_ lhs: WindowSignature, _ rhs: WindowSignature) -> Bool {
        guard mayShareIdentity(lhs, rhs) else { return false }
        if let lhsIDs = lhs.workspaceIDs, let rhsIDs = rhs.workspaceIDs,
           !lhsIDs.isEmpty, lhsIDs == rhsIDs, lhs.checkpointIDs.isEmpty, rhs.checkpointIDs.isEmpty {
            return true
        }
        guard !lhs.checkpointIDs.isEmpty, !rhs.checkpointIDs.isEmpty else { return false }
        if lhs.checkpointIDs == rhs.checkpointIDs, lhs.workspaceCount == rhs.workspaceCount {
            return true
        }
        guard lhs.workspaceCount == rhs.workspaceCount, lhs.workspaceCount > 1 else { return false }
        guard lhs.workspaceTitles.count >= max(3, lhs.workspaceCount - 2),
              lhs.workspaceTitles.count == rhs.workspaceTitles.count,
              lhs.workspaceTitles.sorted() == rhs.workspaceTitles.sorted() else {
            return false
        }
        let overlap = lhs.checkpointIDs.intersection(rhs.checkpointIDs).count
        let smaller = min(lhs.checkpointIDs.count, rhs.checkpointIDs.count)
        return Double(overlap) / Double(smaller) >= 0.75
    }

    private static func mayShareIdentity(_ lhs: WindowSignature, _ rhs: WindowSignature) -> Bool {
        switch (lhs.windowId, rhs.windowId) {
        case let (lhsID?, rhsID?): return lhsID == rhsID
        case (nil, nil): return true
        default: return false
        }
    }
}
