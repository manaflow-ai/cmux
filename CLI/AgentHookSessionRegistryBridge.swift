import CmuxFoundation
import Foundation

/// Converts provider-specific hook models to the shared row-oriented registry.
/// The bridge keeps legacy JSON as a compatibility projection while making the
/// registry authoritative for any row written by this schema generation.
struct AgentHookSessionRegistryBridge {
    enum MutationError: Error {
        case newerWriterGeneration
    }

    let provider: String
    let statePath: String
    let environment: [String: String]
    let fileManager: FileManager

    private var registry: CmuxAgentSessionRegistry {
        CmuxAgentSessionRegistry(url: registryURL)
    }

    private var registryURL: URL {
        if let explicit = normalized(environment["CMUX_AGENT_SESSION_REGISTRY_PATH"]) {
            return URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath)
        }
        if environment["CMUX_CLAUDE_HOOK_STATE_PATH"] != nil
            || environment["CMUX_AGENT_HOOK_STATE_DIR"] != nil {
            return URL(fileURLWithPath: statePath).deletingLastPathComponent()
                .appendingPathComponent(CmuxAgentSessionRegistry.filename, isDirectory: false)
        }
        return CmuxAgentSessionRegistry.defaultURL(environment: environment)
    }

    static func snapshots(
        specifications: [(provider: String, suffix: String)],
        stateDirectory: String,
        environment: [String: String],
        fileManager: FileManager
    ) -> [String: CmuxAgentSessionRegistry.Snapshot]? {
        let registryURL: URL
        if let explicit = environment["CMUX_AGENT_SESSION_REGISTRY_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            registryURL = URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath)
        } else {
            registryURL = URL(fileURLWithPath: stateDirectory, isDirectory: true)
                .appendingPathComponent(CmuxAgentSessionRegistry.filename, isDirectory: false)
        }
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        let sources = specifications.map { specification in
            CmuxAgentSessionRegistry.LegacySource(
                provider: specification.provider,
                url: URL(fileURLWithPath: stateDirectory, isDirectory: true)
                    .appendingPathComponent("\(specification.suffix)-hook-sessions.json", isDirectory: false)
            )
        }
        do {
            return try registry.snapshotsImportingLegacy(
                sources: sources,
                fileManager: fileManager
            )
        } catch {
            var recovered: [String: CmuxAgentSessionRegistry.Snapshot] = [:]
            for source in sources {
                recovered[source.provider] = (try? registry.snapshotImportingLegacy(
                    provider: source.provider,
                    legacyURL: source.url,
                    fileManager: fileManager
                )) ?? (try? registry.snapshot(provider: source.provider))
            }
            return recovered.isEmpty ? nil : recovered
        }
    }

    func load(decoder: JSONDecoder = JSONDecoder()) -> ClaudeHookSessionStoreFile {
        do {
            let snapshot = try registry.snapshotImportingLegacy(
                provider: provider,
                legacyURL: URL(fileURLWithPath: statePath),
                fileManager: fileManager
            )
            return try decode(snapshot, decoder: decoder)
        } catch {
            // Hook reads must remain available when the bounded SQLite busy
            // timeout expires. A corrupt compatibility projection keeps the
            // last complete SQLite snapshot visible. Writers still fail closed.
            if let snapshot = try? registry.snapshot(provider: provider),
               let state = try? decode(snapshot, decoder: decoder) {
                return state
            }
            return readLegacy(decoder: decoder)
        }
    }

    func load(
        snapshot: CmuxAgentSessionRegistry.Snapshot,
        decoder: JSONDecoder = JSONDecoder()
    ) -> ClaudeHookSessionStoreFile {
        (try? decode(snapshot, decoder: decoder)) ?? readLegacy(decoder: decoder)
    }

    func mutate<T>(
        _ body: (inout ClaudeHookSessionStoreFile) throws -> T
    ) throws -> (result: T, state: ClaudeHookSessionStoreFile) {
        _ = try registry.snapshotImportingLegacy(
            provider: provider,
            legacyURL: URL(fileURLWithPath: statePath),
            fileManager: fileManager
        )
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        return try registry.mutateSnapshot(provider: provider) { snapshot in
            var state = try decode(snapshot, decoder: decoder)
            let previous = state
            let result = try body(&state)

            var recordsByID = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.sessionID, $0) })
            for (sessionID, record) in state.sessions {
                guard previous.sessions[sessionID]?.updatedAt != record.updatedAt
                        || previous.sessions[sessionID] == nil else { continue }
                if let existing = recordsByID[sessionID],
                   existing.writerGeneration > CmuxAgentSessionRegistry.currentWriterGeneration {
                    throw MutationError.newerWriterGeneration
                }
                recordsByID[sessionID] = CmuxAgentSessionRegistry.Record(
                    provider: provider,
                    sessionID: sessionID,
                    updatedAt: record.updatedAt,
                    json: try encoder.encode(record)
                )
            }
            for sessionID in Set(previous.sessions.keys).subtracting(state.sessions.keys) {
                guard recordsByID[sessionID]?.writerGeneration ?? 0
                        <= CmuxAgentSessionRegistry.currentWriterGeneration else {
                    throw MutationError.newerWriterGeneration
                }
                recordsByID.removeValue(forKey: sessionID)
            }
            snapshot.records = Array(recordsByID.values)

            let previousSlots = slotMap(previous)
            let currentSlots = slotMap(state)
            var slotsByKey = Dictionary(uniqueKeysWithValues: snapshot.activeSlots.map {
                (CmuxAgentSessionRegistry.slotKey(scope: $0.scope, scopeID: $0.scopeID), $0)
            })
            for (key, slot) in currentSlots {
                let old = previousSlots[key]
                guard old?.record.updatedAt != slot.record.updatedAt
                        || old?.record.sessionId != slot.record.sessionId
                        || old?.record.turnId != slot.record.turnId else { continue }
                if let existing = slotsByKey[key],
                   existing.writerGeneration > CmuxAgentSessionRegistry.currentWriterGeneration {
                    throw MutationError.newerWriterGeneration
                }
                slotsByKey[key] = CmuxAgentSessionRegistry.ActiveSlot(
                    provider: provider,
                    scope: slot.scope,
                    scopeID: slot.scopeID,
                    sessionID: slot.record.sessionId,
                    updatedAt: slot.record.updatedAt,
                    json: try encoder.encode(slot.record)
                )
            }
            for key in Set(previousSlots.keys).subtracting(currentSlots.keys) {
                guard slotsByKey[key]?.writerGeneration ?? 0
                        <= CmuxAgentSessionRegistry.currentWriterGeneration else {
                    throw MutationError.newerWriterGeneration
                }
                slotsByKey.removeValue(forKey: key)
            }
            snapshot.activeSlots = Array(slotsByKey.values)
            return (result, state)
        }
    }

    func markLegacySourceCurrent() {
        guard let stamp = CmuxAgentSessionRegistry.LegacyStamp.read(path: statePath, fileManager: fileManager) else {
            return
        }
        try? registry.markLegacySource(provider: provider, stamp: stamp)
    }

    private func readLegacy(decoder: JSONDecoder) -> ClaudeHookSessionStoreFile {
        guard fileManager.fileExists(atPath: statePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let state = try? decoder.decode(ClaudeHookSessionStoreFile.self, from: data) else {
            return ClaudeHookSessionStoreFile()
        }
        return state
    }

    private func decode(
        _ snapshot: CmuxAgentSessionRegistry.Snapshot,
        decoder: JSONDecoder
    ) throws -> ClaudeHookSessionStoreFile {
        var state = ClaudeHookSessionStoreFile()
        for stored in snapshot.records {
            let record = try decoder.decode(ClaudeHookSessionRecord.self, from: stored.json)
            guard record.sessionId == stored.sessionID else {
                throw ProjectionError.recordIdentityMismatch
            }
            state.sessions[stored.sessionID] = record
        }
        for slot in snapshot.activeSlots {
            let record = try decoder.decode(ClaudeHookActiveSessionRecord.self, from: slot.json)
            guard record.sessionId == slot.sessionID else {
                throw ProjectionError.slotIdentityMismatch
            }
            switch slot.scope {
            case .workspace: state.activeSessionsByWorkspace[slot.scopeID] = record
            case .surface: state.activeSessionsBySurface[slot.scopeID] = record
            }
        }
        return state
    }

    private enum ProjectionError: Error {
        case recordIdentityMismatch
        case slotIdentityMismatch
    }

    private struct SlotValue {
        var scope: CmuxAgentSessionRegistry.Scope
        var scopeID: String
        var record: ClaudeHookActiveSessionRecord
    }

    private func slotMap(_ state: ClaudeHookSessionStoreFile) -> [String: SlotValue] {
        var result: [String: SlotValue] = [:]
        for (scopeID, record) in state.activeSessionsByWorkspace {
            let scope = CmuxAgentSessionRegistry.Scope.workspace
            result[CmuxAgentSessionRegistry.slotKey(scope: scope, scopeID: scopeID)] = SlotValue(
                scope: scope,
                scopeID: scopeID,
                record: record
            )
        }
        for (scopeID, record) in state.activeSessionsBySurface {
            let scope = CmuxAgentSessionRegistry.Scope.surface
            result[CmuxAgentSessionRegistry.slotKey(scope: scope, scopeID: scopeID)] = SlotValue(
                scope: scope,
                scopeID: scopeID,
                record: record
            )
        }
        return result
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
