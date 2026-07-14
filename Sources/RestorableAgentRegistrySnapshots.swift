import CmuxFoundation
import Foundation

extension RestorableAgentSessionIndex {
    static func agentRegistrySnapshots(
        _ sources: [(kind: RestorableAgentKind, fileURL: URL)],
        fileManager: FileManager
    ) -> [String: CmuxAgentSessionRegistry.Snapshot]? {
        guard let registryURL = sources.first?.fileURL.deletingLastPathComponent()
            .appendingPathComponent(CmuxAgentSessionRegistry.filename, isDirectory: false) else {
            return nil
        }
        return try? CmuxAgentSessionRegistry(url: registryURL).snapshotsImportingLegacy(
            sources: sources.map {
                CmuxAgentSessionRegistry.LegacySource(provider: $0.kind.rawValue, url: $0.fileURL)
            },
            fileManager: fileManager
        )
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
