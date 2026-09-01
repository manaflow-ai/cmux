import Foundation
import OSLog

extension CmuxVaultAgentRegistry {
    static let defaultConfigDecodeCache = CmuxConfigDecodeCache()
    private static let configFailureLogGate = CmuxConfigDecodeFailureLogGate()
    private static let configLogger = Logger(subsystem: "ai.manaflow.cmux", category: "VaultAgentRegistry")

    static func decodeConfig(
        at path: String,
        fileManager: FileManager,
        cache: CmuxConfigDecodeCache
    ) -> CmuxConfigFile? {
        guard fileManager.fileExists(atPath: path),
              let data = fileManager.contents(atPath: path),
              !data.isEmpty else {
            return nil
        }

        let cacheKey = cache.key(path: path, data: data, fileManager: fileManager)
        if let cached = cache.entry(for: cacheKey) {
            return cached.config
        }

        do {
            let sanitized = try JSONCParser.preprocess(data: data)
            let config = try JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
            var typeIssues = config.commandDecodingIssues
            if let validatorIssues = try? CmuxConfigTypeValidator(
                workspaceColorNames: Set(WorkspaceTabColorSettings.resolvedPaletteMap().keys)
            ).issues(in: sanitized) {
                typeIssues = CmuxConfigTypeIssue.merged(typeIssues, with: validatorIssues)
            }
            let failureMessage = typeIssues.isEmpty
                ? nil
                : typeIssues.map(\.description).joined(separator: "; ")
            if let failureMessage {
                Self.logDecodeFailure(path: path, message: failureMessage, key: cacheKey)
            }
            cache.insert(config: config, for: cacheKey)
            return config
        } catch {
            let message = Self.decodeErrorMessage(error)
            Self.logDecodeFailure(path: path, message: message, key: cacheKey)
            cache.insert(config: nil, for: cacheKey)
            return nil
        }
    }

    private static func logDecodeFailure(path: String, message: String, key: String) {
        let logger = configLogger
        Task {
            guard await configFailureLogGate.claim(key: key) else { return }
            logger.fault(
                "Failed to decode config at \(path, privacy: .private): \(message, privacy: .private)"
            )
        }
    }

    private static func decodeErrorMessage(_ error: Error) -> String {
        let message = CmuxConfigTypeIssue.decodingMessage(for: error)
        if !message.isEmpty {
            return message
        }
        return error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
    }
}
