import Bonsplit
import Foundation

/// Owns retained surface icons; the caller authorizes full replacements against the live terminal.
@MainActor
final class SurfaceIconLeaseStore {
    struct Entry: Sendable {
        let panelID: UUID
        let ownerID: String
        let token: UUID
        let revision: Int
        /// Changes for every full replacement, including reacquisition after a producer restart.
        let generation: UUID
        let animation: TabIconAnimation
    }

    enum LeaseError: Error, Equatable {
        case ownershipConflict
        case staleToken
        case revisionConflict
        case missingAnimation
    }

    private var entries: [UUID: Entry] = [:]
    private let onChange: (UUID, TabIconAnimation?) -> Void

    init(onChange: @escaping (UUID, TabIconAnimation?) -> Void) {
        self.onChange = onChange
    }

    /// Full asset-only sets replace the current generation after caller authorization.
    /// Token-bearing updates remain conditional; a nil animation preserves the current pixels.
    @discardableResult
    func set(panelID: UUID, ownerID: String, token: UUID? = nil, expectedRevision: Int? = nil,
             animation: TabIconAnimation? = nil) throws -> Entry {
        let entry: Entry
        if let token {
            guard let previous = entries[panelID] else { throw LeaseError.staleToken }
            guard previous.ownerID == ownerID else { throw LeaseError.ownershipConflict }
            guard previous.token == token else { throw LeaseError.staleToken }
            guard let expectedRevision, previous.revision == expectedRevision,
                  previous.revision < Int.max else { throw LeaseError.revisionConflict }
            entry = Entry(panelID: panelID, ownerID: ownerID, token: token,
                          revision: previous.revision + 1, generation: previous.generation,
                          animation: animation ?? previous.animation)
        } else {
            guard expectedRevision == nil else { throw LeaseError.revisionConflict }
            guard let animation else { throw LeaseError.missingAnimation }
            entry = Entry(panelID: panelID, ownerID: ownerID, token: UUID(),
                          revision: 1, generation: UUID(), animation: animation)
        }
        entries[panelID] = entry
        onChange(panelID, entry.animation)
        return entry
    }

    func clear(panelID: UUID, ownerID: String, token: UUID, expectedRevision: Int? = nil) throws {
        guard let entry = entries[panelID] else { throw LeaseError.staleToken }
        guard entry.ownerID == ownerID else { throw LeaseError.ownershipConflict }
        guard entry.token == token else { throw LeaseError.staleToken }
        guard let expectedRevision, entry.revision == expectedRevision else {
            throw LeaseError.revisionConflict
        }
        reset(panelID: panelID)
    }

    func entry(for panelID: UUID) -> Entry? {
        entries[panelID]
    }

    func reset(panelID: UUID) {
        guard entries.removeValue(forKey: panelID) != nil else { return }
        onChange(panelID, nil)
    }

    func resetAll() {
        // Snapshot before callbacks; callbacks may query the store.
        let panelIDs = Array(entries.keys)
        for panelID in panelIDs { reset(panelID: panelID) }
    }
}
