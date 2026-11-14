public import Foundation

/// What a session-snapshot window looks like to crash-duplicate detection.
/// The app builds one for each window and merges the pairs where
/// `isCrashDuplicate(of:)` holds: the same window written twice by a crash.
public struct CrashWindowSignature: Equatable, Sendable {
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
    public func isCrashDuplicate(of other: CrashWindowSignature) -> Bool {
        guard mayShareIdentity(with: other) else {
            return isReplayWithNewWindowID(of: other)
        }
        if let ownIDs = workspaceIDs, let otherIDs = other.workspaceIDs,
           !ownIDs.isEmpty, ownIDs == otherIDs, checkpointIDs.isEmpty, other.checkpointIDs.isEmpty {
            return true
        }
        guard !checkpointIDs.isEmpty, !other.checkpointIDs.isEmpty else { return false }
        if checkpointIDs == other.checkpointIDs, workspaceCount == other.workspaceCount {
            return true
        }
        // The title rule needs at least three titled workspaces, so a
        // one- or two-workspace window never merges on overlap alone.
        guard workspaceCount == other.workspaceCount,
              hasSameTitleMultiset(as: other) else { return false }
        let overlap = checkpointIDs.intersection(other.checkpointIDs).count
        let smaller = min(checkpointIDs.count, other.checkpointIDs.count)
        return Double(overlap) / Double(smaller) >= 0.75
    }
}

extension CrashWindowSignature {
    private func isReplayWithNewWindowID(of other: CrashWindowSignature) -> Bool {
        guard workspaceCount == other.workspaceCount,
              hasSameTitleMultiset(as: other) else {
            return false
        }
        let (smaller, larger) = checkpointIDs.count <= other.checkpointIDs.count
            ? (checkpointIDs, other.checkpointIDs)
            : (other.checkpointIDs, checkpointIDs)
        return smaller.count >= 2 && smaller.isSubset(of: larger)
    }

    private func hasSameTitleMultiset(as other: CrashWindowSignature) -> Bool {
        workspaceTitles.count >= max(3, workspaceCount - 2)
            && workspaceTitles.count == other.workspaceTitles.count
            && workspaceTitles.sorted() == other.workspaceTitles.sorted()
    }

    private func mayShareIdentity(with other: CrashWindowSignature) -> Bool {
        switch (windowId, other.windowId) {
        case let (ownID?, otherID?): return ownID == otherID
        case (nil, nil): return true
        default: return false
        }
    }
}
