import Foundation

/// Complete replicated state for one TextBox document.
public struct WorkspaceShareTextSnapshot: Codable, Equatable, Sendable {
    /// Stable document identifier.
    public let docId: String
    /// Host-accepted operation revision.
    public let revision: UInt64
    /// All live and tombstoned sequence atoms.
    public let atoms: [WorkspaceShareTextAtom]

    /// Creates a text snapshot.
    /// - Parameters:
    ///   - docId: Stable document identifier.
    ///   - revision: Host revision.
    ///   - atoms: Sequence atoms.
    public init(docId: String, revision: UInt64, atoms: [WorkspaceShareTextAtom]) {
        self.docId = docId
        self.revision = revision
        self.atoms = atoms
    }
}
