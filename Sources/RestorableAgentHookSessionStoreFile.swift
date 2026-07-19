import CmuxFoundation
import Darwin
import Foundation

struct RestorableAgentHookSessionStoreFile: Codable, Sendable {
    var version: Int = 1
    var sessions: [String: RestorableAgentHookSessionRecord] = [:]
}

extension RestorableAgentHookSessionStoreFile {
    static func decode(
        snapshot: CmuxAgentSessionRegistry.Snapshot,
        decoder: JSONDecoder
    ) throws -> Self {
        var state = Self()
        for stored in snapshot.records {
            let record = try decoder.decode(RestorableAgentHookSessionRecord.self, from: stored.json)
            guard record.sessionId == stored.sessionID else {
                throw ProjectionError.recordIdentityMismatch
            }
            state.sessions[stored.sessionID] = record
        }
        return state
    }

    private enum ProjectionError: Error {
        case recordIdentityMismatch
    }

    /// Loads the authoritative registry snapshot, importing changed legacy JSON
    /// first. The import is raw so fields unknown to this app model survive.
    static func load(
        provider: String,
        legacyURL: URL,
        environment: [String: String],
        fileManager: FileManager,
        decoder: JSONDecoder
    ) -> Self? {
        let registryURL: URL
        if let explicit = environment["CMUX_AGENT_SESSION_REGISTRY_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            registryURL = URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath)
        } else {
            registryURL = legacyURL.deletingLastPathComponent()
                .appendingPathComponent(CmuxAgentSessionRegistry.filename, isDirectory: false)
        }
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        do {
            let snapshot = try registry.snapshotImportingLegacy(
                provider: provider,
                legacyURL: legacyURL,
                fileManager: fileManager
            )
            return try decode(snapshot: snapshot, decoder: decoder)
        } catch {
            do {
                let snapshot = try registry.snapshot(provider: provider)
                return try? decode(snapshot: snapshot, decoder: decoder)
            } catch {
                guard registryStorageIsTrulyAbsent(at: registryURL),
                      fileManager.fileExists(atPath: legacyURL.path),
                      let data = try? registry.readHookLegacySourceData(at: legacyURL),
                      registryStorageIsTrulyAbsent(at: registryURL) else {
                    return nil
                }
                return try? decoder.decode(Self.self, from: data)
            }
        }
    }

    /// Legacy JSON is only authoritative before the SQLite registry exists.
    /// Treat permission errors, dangling symlinks, and SQLite sidecars as
    /// possible registry state so an unreadable canonical store fails closed.
    private static func registryStorageIsTrulyAbsent(at registryURL: URL) -> Bool {
        let paths = [
            registryURL.path,
            registryURL.path + "-wal",
            registryURL.path + "-shm",
            registryURL.path + "-journal",
        ]
        return paths.allSatisfy { path in
            var metadata = stat()
            guard lstat(path, &metadata) != 0 else { return false }
            return errno == ENOENT || errno == ENOTDIR
        }
    }
}
