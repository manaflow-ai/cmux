/// Deterministic validation failure produced while building or reducing topology.
public enum NestedTopologyValidationError: Error, Equatable, Sendable {
    /// A required field was empty after trimming.
    case emptyField(String)
    /// A string field exceeded the configured UTF-8 byte limit.
    case fieldTooLarge(field: String, byteCount: Int, limit: Int)
    /// Encoding version is unsupported.
    case unsupportedEncodingVersion(UInt8)
    /// Node kind does not match the ID's declared kind.
    case kindMismatch(expected: NestedNodeKind, actual: NestedNodeKind)
    /// Parent is missing, wrong kind, or belongs to another provider instance.
    case malformedParent(child: NestedNodeID, parent: NestedNodeID?, reason: String)
    /// Two nodes share the same compound ID.
    case duplicateNodeID(NestedNodeID)
    /// Parent chain forms a cycle.
    case cycleDetected(NestedNodeID)
    /// Tree depth exceeds ``NestedTopologyLimits/maxDepth``.
    case depthExceeded(kind: NestedNodeKind, depth: Int, limit: Int)
    /// Collection count exceeds a configured limit.
    case countExceeded(collection: String, count: Int, limit: Int)
    /// Focus references a missing or wrong-kind node.
    case invalidFocus(reason: String)
    /// Agent status payload is invalid.
    case invalidStatus(reason: String)
    /// Event targets a provider instance that does not match the reducer.
    case providerInstanceMismatch
    /// Event cannot be applied because no snapshot is installed.
    case snapshotRequired
    /// Event references an unknown node where presence is required.
    case unknownNode(NestedNodeID)
}
