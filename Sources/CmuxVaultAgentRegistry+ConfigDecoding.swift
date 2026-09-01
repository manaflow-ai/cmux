import Foundation
import OSLog

extension CmuxVaultAgentRegistry {
    private static let configDecodeCache = CmuxConfigDecodeCache()
    private static let configLogger = Logger(subsystem: "ai.manaflow.cmux", category: "VaultAgentRegistry")

    static func decodeConfig(at path: String, fileManager: FileManager) -> CmuxConfigFile? {
        guard fileManager.fileExists(atPath: path),
              let data = fileManager.contents(atPath: path),
              !data.isEmpty else {
            return nil
        }

        let cacheKey = configDecodeCache.key(path: path, data: data, fileManager: fileManager)
        if let cached = configDecodeCache.entry(for: cacheKey) {
            return cached.config
        }

        do {
            let sanitized = try JSONCParser.preprocess(data: data)
            let config = try JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
            var typeIssues = config.commandDecodingIssues
            if let validatorIssues = try? CmuxConfigTypeValidator().issues(in: sanitized) {
                for validatorIssue in validatorIssues where !typeIssues.contains(validatorIssue) {
                    typeIssues.append(validatorIssue)
                }
            }
            let failureMessage = typeIssues.isEmpty
                ? nil
                : typeIssues.map(\.description).joined(separator: "; ")
            if let failureMessage {
                Self.logDecodeFailure(path: path, message: failureMessage)
            }
            configDecodeCache.insert(config: config, failureMessage: failureMessage, for: cacheKey)
            return config
        } catch {
            let message = Self.decodeErrorMessage(error)
            Self.logDecodeFailure(path: path, message: message)
            configDecodeCache.insert(config: nil, failureMessage: message, for: cacheKey)
            return nil
        }
    }

    private static func logDecodeFailure(path: String, message: String) {
        configLogger.fault(
            "Failed to decode config at \(path, privacy: .public): \(message, privacy: .public)"
        )
    }

    private static func decodeErrorMessage(_ error: Error) -> String {
        let message = CmuxConfigTypeIssue.decodingMessage(for: error)
        if !message.isEmpty {
            return message
        }
        return error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
    }
}
