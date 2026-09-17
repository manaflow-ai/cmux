import Foundation

/// A deterministic replicated growable array for plain-text TextBox content.
public struct WorkspaceShareTextDocument: Equatable, Sendable {
    /// Maximum atoms carried by one complete TextBox snapshot.
    public static let maximumSnapshotAtoms = 8_000
    /// Maximum atoms carried by one incremental TextBox operation.
    public static let maximumOperationAtoms = 256
    private static let maximumIdentifierClock: UInt64 = 999_999_999
    private static let maximumAppliedOperationHistory = 16_384

    /// Stable document identifier.
    public let docId: String
    /// Host-accepted operation revision.
    public private(set) var revision: UInt64

    private var atomsByID: [String: WorkspaceShareTextAtom]
    private var appliedOperationIDs: Set<String>
    private var appliedOperationIDOrder: [String]
    private var deletedAtomIDs: Set<String>
    private var logicalClock: UInt64

    /// Restores a document from a complete snapshot.
    /// - Parameter snapshot: Authoritative document snapshot.
    public init(snapshot: WorkspaceShareTextSnapshot) {
        docId = snapshot.docId
        revision = snapshot.revision
        appliedOperationIDs = []
        appliedOperationIDOrder = []
        let validAtoms = snapshot.atoms.prefix(Self.maximumSnapshotAtoms).filter(Self.valid(atom:))
        atomsByID = Dictionary(validAtoms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        deletedAtomIDs = Set(validAtoms.lazy.filter(\.deleted).map(\.id))
        logicalClock = validAtoms.compactMap { Self.identifierClock($0.id) }.max() ?? 0
    }

    /// Creates a document from ordinary text using stable host atom identifiers.
    /// - Parameters:
    ///   - docId: Stable document identifier.
    ///   - text: Initial plain text.
    ///   - clientID: Identifier suffix used for the initial atoms.
    public init(docId: String, text: String, clientID: String = "host") {
        self.docId = docId
        revision = 0
        appliedOperationIDs = []
        appliedOperationIDOrder = []
        deletedAtomIDs = []
        logicalClock = 0
        var previousID: String?
        var atoms: [String: WorkspaceShareTextAtom] = [:]
        guard Self.valid(clientID: clientID) else {
            atomsByID = atoms
            return
        }
        for (index, character) in text.prefix(Self.maximumSnapshotAtoms).enumerated() {
            let id = Self.identifier(clock: UInt64(index + 1), clientID: clientID)
            atoms[id] = WorkspaceShareTextAtom(
                id: id,
                afterId: previousID,
                value: String(character)
            )
            previousID = id
            logicalClock = UInt64(index + 1)
        }
        atomsByID = atoms
    }

    /// Current visible plain text.
    public var text: String {
        visibleAtoms.map(\.value).joined()
    }

    /// Complete state used for a newly approved or reconnected viewer.
    public var snapshot: WorkspaceShareTextSnapshot {
        WorkspaceShareTextSnapshot(
            docId: docId,
            revision: revision,
            atoms: atomsByID.values.sorted { $0.id < $1.id }
        )
    }

    /// Applies one idempotent remote or local operation.
    /// - Parameters:
    ///   - operation: Operation to apply.
    ///   - acceptedRevision: Optional host revision carried by the server.
    /// - Returns: Whether this operation was newly applied.
    @discardableResult
    public mutating func apply(
        _ operation: WorkspaceShareTextOperation,
        acceptedRevision: UInt64? = nil,
        expectedClientID: String? = nil
    ) -> Bool {
        guard operation.docId == docId,
              Self.valid(identifier: operation.opId),
              expectedClientID.map({ Self.identifierClientID(operation.opId) == $0 }) ?? true,
              Self.operationClocks(operation).allSatisfy({
                  $0 <= min(Self.maximumIdentifierClock, logicalClock + UInt64(Self.maximumOperationAtoms + 1))
              }) else { return false }
        if appliedOperationIDs.contains(operation.opId) {
            if let acceptedRevision { revision = max(revision, acceptedRevision) }
            return false
        }
        switch operation.kind {
        case .insert:
            guard let atoms = operation.atoms,
                  (1...Self.maximumOperationAtoms).contains(atoms.count),
                  atoms.allSatisfy(Self.valid(atom:)),
                  expectedClientID.map({ expected in
                      atoms.allSatisfy { Self.identifierClientID($0.id) == expected }
                  }) ?? true else { return false }
            for atom in atoms {
                observe(identifier: atom.id)
                if atomsByID[atom.id] == nil, atomsByID.count < Self.maximumSnapshotAtoms {
                    atomsByID[atom.id] = WorkspaceShareTextAtom(
                        id: atom.id,
                        afterId: atom.afterId,
                        value: atom.value,
                        deleted: deletedAtomIDs.contains(atom.id)
                    )
                }
            }
        case .delete:
            guard let atomIDs = operation.atomIds,
                  (1...Self.maximumOperationAtoms).contains(atomIDs.count),
                  atomIDs.allSatisfy(Self.valid(identifier:)),
                  expectedClientID == nil || atomIDs.allSatisfy({ atomsByID[$0] != nil }) else {
                return false
            }
            for atomID in atomIDs {
                observe(identifier: atomID)
                if atomsByID[atomID] != nil || deletedAtomIDs.count < Self.maximumSnapshotAtoms {
                    deletedAtomIDs.insert(atomID)
                }
                guard let atom = atomsByID[atomID], !atom.deleted else { continue }
                atomsByID[atomID] = WorkspaceShareTextAtom(
                    id: atom.id,
                    afterId: atom.afterId,
                    value: atom.value,
                    deleted: true
                )
            }
        }
        observe(identifier: operation.opId)
        appliedOperationIDs.insert(operation.opId)
        appliedOperationIDOrder.append(operation.opId)
        if appliedOperationIDOrder.count >= Self.maximumAppliedOperationHistory * 2 {
            appliedOperationIDOrder.removeFirst(Self.maximumAppliedOperationHistory)
            appliedOperationIDs = Set(appliedOperationIDOrder)
        }
        revision = max(revision &+ 1, acceptedRevision ?? 0)
        return true
    }

    /// Converts one committed local replacement into bounded delete and insert operations.
    /// - Parameters:
    ///   - nextText: Committed plain text after the edit.
    ///   - clientID: Stable participant identifier suffix.
    ///   - counter: Monotonic participant counter updated for generated IDs.
    /// - Returns: Newly applied operations to send to peers.
    public mutating func localChange(
        to nextText: String,
        clientID: String,
        counter: inout UInt64
    ) -> [WorkspaceShareTextOperation] {
        let current = visibleAtoms
        let before = current.map { Character($0.value) }
        let after = Array(nextText)
        guard after.count <= Self.maximumSnapshotAtoms,
              Self.valid(clientID: clientID) else { return [] }
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < before.count - prefix,
              suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] {
            suffix += 1
        }

        var operations: [WorkspaceShareTextOperation] = []
        let removed = Array(current[prefix..<(before.count - suffix)].map(\.id))
        for atomIDs in removed.chunked(maximumCount: Self.maximumOperationAtoms) {
            guard let opID = nextID(clientID: clientID, counter: &counter) else { return operations }
            let operation = WorkspaceShareTextOperation.delete(
                opId: opID,
                docId: docId,
                atomIds: atomIDs
            )
            if apply(operation) { operations.append(operation) }
        }

        let inserted = Array(after[prefix..<(after.count - suffix)])
        var afterID = prefix > 0 ? current[prefix - 1].id : nil
        for characters in inserted.chunked(maximumCount: Self.maximumOperationAtoms) {
            var atoms: [WorkspaceShareTextAtom] = []
            for character in characters {
                guard let id = nextID(clientID: clientID, counter: &counter) else { return operations }
                atoms.append(WorkspaceShareTextAtom(id: id, afterId: afterID, value: String(character)))
                afterID = id
            }
            guard let opID = nextID(clientID: clientID, counter: &counter) else { return operations }
            let operation = WorkspaceShareTextOperation.insert(
                opId: opID,
                docId: docId,
                atoms: atoms
            )
            if apply(operation) { operations.append(operation) }
        }
        return operations
    }

    private var visibleAtoms: [WorkspaceShareTextAtom] {
        var children: [String?: [WorkspaceShareTextAtom]] = [:]
        for atom in atomsByID.values {
            let parent = atom.afterId.flatMap { atomsByID[$0] == nil ? nil : $0 }
            children[parent, default: []].append(atom)
        }
        for key in children.keys {
            children[key]?.sort { $0.id > $1.id }
        }
        var result: [WorkspaceShareTextAtom] = []
        var seen: Set<String> = []
        func visit(_ parent: String?) {
            for atom in children[parent] ?? [] where seen.insert(atom.id).inserted {
                if !atom.deleted { result.append(atom) }
                visit(atom.id)
            }
        }
        visit(nil)
        return result
    }

    private static func valid(atom: WorkspaceShareTextAtom) -> Bool {
        valid(identifier: atom.id)
            && (atom.afterId.map(valid(identifier:)) ?? true)
            && atom.value.count == 1
            && atom.value.utf8.count <= 64
    }

    private static func valid(identifier: String) -> Bool {
        identifierClock(identifier) != nil
    }

    private static func valid(clientID: String) -> Bool {
        guard (1...128).contains(clientID.count) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return clientID.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func identifierClock(_ identifier: String) -> UInt64? {
        guard let separator = identifier.firstIndex(of: ":") else { return nil }
        let clock = identifier[..<separator]
        let clientID = String(identifier[identifier.index(after: separator)...])
        guard clock.count == 12,
              clock.allSatisfy(\.isNumber),
              valid(clientID: clientID),
              let value = UInt64(clock),
              value <= maximumIdentifierClock else { return nil }
        return value
    }

    private static func identifierClientID(_ identifier: String) -> String? {
        guard let separator = identifier.firstIndex(of: ":") else { return nil }
        return String(identifier[identifier.index(after: separator)...])
    }

    private static func operationClocks(_ operation: WorkspaceShareTextOperation) -> [UInt64] {
        var identifiers = [operation.opId]
        identifiers.append(contentsOf: operation.atoms?.flatMap { atom in
            [atom.id, atom.afterId].compactMap { $0 }
        } ?? [])
        identifiers.append(contentsOf: operation.atomIds ?? [])
        return identifiers.compactMap(identifierClock)
    }

    private static func identifier(clock: UInt64, clientID: String) -> String {
        String(format: "%012llu:%@", clock, clientID)
    }

    private mutating func nextID(clientID: String, counter: inout UInt64) -> String? {
        guard counter < Self.maximumIdentifierClock,
              logicalClock < Self.maximumIdentifierClock else { return nil }
        counter += 1
        logicalClock = max(logicalClock + 1, counter)
        guard logicalClock <= Self.maximumIdentifierClock else { return nil }
        return Self.identifier(clock: logicalClock, clientID: clientID)
    }

    private mutating func observe(identifier: String) {
        if let clock = Self.identifierClock(identifier) {
            logicalClock = max(logicalClock, clock)
        }
    }
}

private extension Array {
    func chunked(maximumCount: Int) -> [[Element]] {
        guard maximumCount > 0 else { return [] }
        return stride(from: 0, to: count, by: maximumCount).map { start in
            Array(self[start..<Swift.min(start + maximumCount, count)])
        }
    }
}
