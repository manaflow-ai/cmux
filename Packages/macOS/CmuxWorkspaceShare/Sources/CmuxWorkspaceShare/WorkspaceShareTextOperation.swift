import Foundation

/// One idempotent insertion or deletion in a shared TextBox document.
public struct WorkspaceShareTextOperation: Codable, Equatable, Sendable {
    /// Operation identifier used for deduplication.
    public let opId: String
    /// Document receiving the operation.
    public let docId: String
    /// Either `insert` or `delete`.
    public let kind: Kind
    /// Inserted atoms for an `insert` operation.
    public let atoms: [WorkspaceShareTextAtom]?
    /// Tombstoned atom identifiers for a `delete` operation.
    public let atomIds: [String]?

    /// Supported text operation kinds.
    public enum Kind: String, Codable, Equatable, Sendable {
        /// Insert one or more atoms.
        case insert
        /// Tombstone one or more atoms.
        case delete
    }

    /// Creates an insertion.
    /// - Parameters:
    ///   - opId: Operation identifier.
    ///   - docId: Document identifier.
    ///   - atoms: Inserted atoms.
    /// - Returns: Insertion operation.
    public static func insert(opId: String, docId: String, atoms: [WorkspaceShareTextAtom]) -> Self {
        Self(opId: opId, docId: docId, kind: .insert, atoms: atoms, atomIds: nil)
    }

    /// Creates a deletion.
    /// - Parameters:
    ///   - opId: Operation identifier.
    ///   - docId: Document identifier.
    ///   - atomIds: Tombstoned atom identifiers.
    /// - Returns: Deletion operation.
    public static func delete(opId: String, docId: String, atomIds: [String]) -> Self {
        Self(opId: opId, docId: docId, kind: .delete, atoms: nil, atomIds: atomIds)
    }

    private init(
        opId: String,
        docId: String,
        kind: Kind,
        atoms: [WorkspaceShareTextAtom]?,
        atomIds: [String]?
    ) {
        self.opId = opId
        self.docId = docId
        self.kind = kind
        self.atoms = atoms
        self.atomIds = atomIds
    }

    enum CodingKeys: String, CodingKey {
        case opId
        case docId
        case kind
        case atoms
        case atomIds
    }
}
