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
        let lookup = cache.lookupOrClaim(cacheKey)
        if case .hit(let cached) = lookup {
            return cached.config
        }
        let isFirstLoader: Bool
        if case .miss(let firstLoader) = lookup {
            isFirstLoader = firstLoader
        } else {
            isFirstLoader = false
        }
        // Only the owner releases the in-flight claim. Followers may finish
        // first, and releasing from a follower would let a third caller claim
        // the same cold revision while the owner is still decoding.
        defer {
            cache.finishLoading(cacheKey, isOwner: isFirstLoader)
        }

        do {
            let sanitized = try JSONCParser.preprocess(data: data)
            let decoded = try CmuxConfigFile.decodeAndValidate(
                sanitizedData: sanitized,
                workspaceColorPalette: WorkspaceTabColorSettings.resolvedPaletteMap()
            )
            if isFirstLoader, let failureMessage = decoded.typeIssueMessage {
                Self.logDecodeFailure(path: path, message: failureMessage, key: cacheKey)
            }
            cache.insert(config: decoded.config, for: cacheKey)
            return decoded.config
        } catch {
            let message = Self.decodeErrorMessage(error)
            if isFirstLoader {
                Self.logDecodeFailure(path: path, message: message, key: cacheKey)
            }
            cache.insert(config: nil, for: cacheKey)
            return nil
        }
    }

    private static func logDecodeFailure(path: String, message: String, key: String) {
        guard configFailureLogGate.claim(path: path, key: key) else { return }
        configLogger.fault(
            "Failed to decode config at \(path, privacy: .private(mask: .hash)): \(message, privacy: .private)"
        )
    }

    private static func decodeErrorMessage(_ error: Error) -> String {
        let message = CmuxConfigTypeIssue.decodingMessage(for: error)
        if !message.isEmpty {
            return message
        }
        let fallback = error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
        return CmuxConfigTypeIssue.sanitizeText(fallback, replacingNewlines: true)
    }
}
