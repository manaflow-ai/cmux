import CmuxFoundation
import Foundation

extension RestorableAgentSessionIndex {
    static func agentRegistrySnapshots(
        _ sources: [(kind: RestorableAgentKind, fileURL: URL)],
        fileManager: FileManager,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: CmuxAgentSessionRegistry.Snapshot]? {
        guard let firstSource = sources.first else {
            return nil
        }
        let registryURL: URL
        if let explicit = environment["CMUX_AGENT_SESSION_REGISTRY_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            registryURL = URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath)
        } else {
            registryURL = firstSource.fileURL.deletingLastPathComponent()
                .appendingPathComponent(CmuxAgentSessionRegistry.filename, isDirectory: false)
        }
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        let legacySources = sources.map {
            CmuxAgentSessionRegistry.LegacySource(provider: $0.kind.rawValue, url: $0.fileURL)
        }
        do {
            return try registry.snapshotsImportingLegacy(
                sources: legacySources,
                fileManager: fileManager
            )
        } catch {
            var recovered: [String: CmuxAgentSessionRegistry.Snapshot] = [:]
            for source in legacySources {
                recovered[source.provider] = (try? registry.snapshotImportingLegacy(
                    provider: source.provider,
                    legacyURL: source.url,
                    fileManager: fileManager
                )) ?? (try? registry.snapshot(provider: source.provider))
            }
            return recovered.isEmpty ? nil : recovered
        }
    }

    static func agentHookState(
        kind: RestorableAgentKind,
        fileURL: URL,
        snapshots: [String: CmuxAgentSessionRegistry.Snapshot]?,
        fileManager: FileManager,
        decoder: JSONDecoder
    ) -> RestorableAgentHookSessionStoreFile? {
        snapshots?[kind.rawValue].map {
            RestorableAgentHookSessionStoreFile.decode(snapshot: $0, decoder: decoder)
        } ?? RestorableAgentHookSessionStoreFile.load(
            provider: kind.rawValue,
            legacyURL: fileURL,
            environment: ProcessInfo.processInfo.environment,
            fileManager: fileManager,
            decoder: decoder
        )
    }
}
