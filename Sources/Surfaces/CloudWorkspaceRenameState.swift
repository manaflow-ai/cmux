import CoreFoundation
import Foundation

/// The monotonic position of a cloud daemon's session graph.
///
/// A revision is comparable only inside its generation.  The generation changes when the
/// daemon creates a new graph, so callers must treat generations as opaque and never order
/// values from different generations.
struct CloudVMCursor: Codable, Equatable, Hashable, Sendable {
    let generation: String
    let revision: UInt64

    init(generation: String, revision: UInt64) {
        self.generation = generation
        self.revision = revision
    }

    /// Decodes a cursor from a session snapshot.  Both the current string wire form and
    /// legacy JSON numbers are accepted, but booleans, fractions, and negative values fail.
    init?(snapshot: [String: Any]) {
        guard let raw = snapshot["cursor"], !(raw is NSNull),
              let cursor = raw as? [String: Any] else {
            return nil
        }
        self.init(wire: cursor)
    }

    /// Decodes a cursor object returned by a mutation or event envelope.
    init?(wire: [String: Any]) {
        guard let generation = (wire["generation"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !generation.isEmpty,
            let revision = Self.unsigned(wire["revision"]) else {
            return nil
        }
        self.init(generation: generation, revision: revision)
    }

    /// Returns whether `other` is the same generation and no older than this cursor.
    func isAtOrAfter(_ other: CloudVMCursor) -> Bool {
        generation == other.generation && revision >= other.revision
    }

    /// Returns whether this cursor is strictly newer than `other` in the same generation.
    func isNewer(than other: CloudVMCursor?) -> Bool {
        guard let other else { return true }
        return generation == other.generation && revision > other.revision
    }

    private enum CodingKeys: String, CodingKey {
        case generation
        case revision
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let generation = try container.decode(String.self, forKey: .generation)
        if let revision = try? container.decode(UInt64.self, forKey: .revision) {
            self.init(generation: generation, revision: revision)
        } else {
            let raw = try container.decode(String.self, forKey: .revision)
            guard let revision = UInt64(raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .revision,
                    in: container,
                    debugDescription: "revision is not an unsigned integer"
                )
            }
            self.init(generation: generation, revision: revision)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generation, forKey: .generation)
        try container.encode(String(revision), forKey: .revision)
    }

    private static func unsigned(_ raw: Any?) -> UInt64? {
        if raw is Bool { return nil }
        if let value = raw as? UInt64 { return value }
        if let value = raw as? Int { return value >= 0 ? UInt64(value) : nil }
        if let value = raw as? String {
            return UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue >= 0,
              number.doubleValue.rounded() == number.doubleValue else {
            return nil
        }
        return UInt64(number.stringValue)
    }
}

/// Stable identity for one workspace in one cloud machine.
struct CloudWorkspaceRenameKey: Hashable, Sendable {
    let machine: SurfaceMachineID
    let workspaceID: String
}

/// A local rename intent that remains visible until a newer remote graph confirms it.
struct CloudWorkspaceRenameIntent: Sendable {
    let sequence: UInt64
    let name: String
    let previousName: String
    let baselineCursor: CloudVMCursor?
    var receiptCursor: CloudVMCursor?
    var observedGeneration: String?
    var observedRevision: UInt64?
}

/// A token for an optimistic rename.  Rollback is valid only while this token is current;
/// a later edit therefore cannot be reverted by an older network completion.
struct CloudWorkspaceRenameToken: Hashable, Sendable {
    let key: CloudWorkspaceRenameKey
    let sequence: UInt64
    let previousName: String
    let baselineCursor: CloudVMCursor?
}

/// Serializes rename requests for one remote identity without sharing mutable state across
/// actors.  The catalog still owns names and reconciliation; this type only prevents two
/// entry points from issuing the same identity's writes out of order.
@MainActor
final class CloudWorkspaceRenameCoordinator {
    private var tails: [CloudWorkspaceRenameKey: Task<Void, Never>] = [:]
    private var tailIDs: [CloudWorkspaceRenameKey: UUID] = [:]

    /// Runs one operation after the previous operation for the same identity settles.
    /// A failed predecessor does not prevent a later request from running.
    func enqueue(
        key: CloudWorkspaceRenameKey,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        let previous = tails[key]
        let operationTask = Task<Void, Error> { @MainActor in
            if let previous {
                _ = await previous.value
            }
            try Task.checkCancellation()
            try await operation()
        }
        let laneID = UUID()
        tails[key] = Task { @MainActor in
            _ = try? await operationTask.value
        }
        tailIDs[key] = laneID
        defer {
            if tailIDs[key] == laneID {
                tails[key] = nil
                tailIDs[key] = nil
            }
        }
        try await operationTask.value
    }
}
