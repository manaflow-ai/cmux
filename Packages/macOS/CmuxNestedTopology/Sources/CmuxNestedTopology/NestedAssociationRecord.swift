/// In-memory association record shared by native and plugin two-pass semantics.
///
/// No filesystem I/O is performed here; persistence belongs to later attachment PRs
/// or the external plugin bridge.
public struct NestedAssociationRecord: Hashable, Codable, Sendable {
    /// Association key.
    public let key: NestedAssociationKey
    /// Resolved parent tab/workspace compound ID when known.
    public var parentID: NestedNodeID?
    /// Explicit flag: heuristic association already succeeded for this key.
    public var heuristicSatisfied: Bool
    /// Optional native-title lock.
    public var titleLock: NestedTitleLock?

    enum CodingKeys: String, CodingKey {
        case key
        case parentID = "parent_id"
        case heuristicSatisfied = "heuristic_satisfied"
        case titleLock = "title_lock"
    }

    /// Creates an association record.
    public init(
        key: NestedAssociationKey,
        parentID: NestedNodeID? = nil,
        heuristicSatisfied: Bool = false,
        titleLock: NestedTitleLock? = nil
    ) {
        self.key = key
        self.parentID = parentID
        self.heuristicSatisfied = heuristicSatisfied
        self.titleLock = titleLock
    }

    /// Whether heuristic association may still run for this record.
    public var shouldRunHeuristic: Bool {
        !heuristicSatisfied
    }

    /// Resolves a proposed title against the native-title lock.
    ///
    /// - Parameter proposed: Candidate title from provider/heuristic.
    /// - Returns: Locked title when locked; otherwise the proposed title.
    public func resolvedTitle(proposed: String) -> String {
        if let titleLock, titleLock.isLocked, let lockedTitle = titleLock.lockedTitle {
            return lockedTitle
        }
        return proposed
    }

    /// Whether applying `proposed` would change the effective title.
    public func wouldOverwriteLockedTitle(with proposed: String) -> Bool {
        guard let titleLock, titleLock.isLocked else { return false }
        guard let lockedTitle = titleLock.lockedTitle else { return false }
        return lockedTitle != proposed
    }
}
