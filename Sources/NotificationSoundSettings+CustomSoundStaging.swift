import Foundation

/// Shared notification-sound staging facade.
///
/// Every operation that can create, replace, transcode, or inspect a managed
/// staging artifact is routed through one ``NotificationSoundStager`` actor.
/// This keeps the global picker and sparse per-agent matrix on the same cache
/// and prevents concurrent selections from replacing the same destination.
extension NotificationSoundSettings {
    static let customSoundBaseName = "cmux-custom-notification-sound"
    static let systemSoundBaseName = "cmux-system-notification-sound"
    static let systemSoundDirectoryURL = URL(
        fileURLWithPath: "/System/Library/Sounds",
        isDirectory: true
    )

    static let supportedCustomSoundExtensions: Set<String> = [
        "aif",
        "aiff",
        "caf",
        "wav",
    ]

    nonisolated private static let soundStager = NotificationSoundStager()

    nonisolated enum CustomSoundPreparationIssue: Error, Sendable {
        case emptyPath
        case missingFile(path: String)
        case missingFileExtension(path: String)
        case stagingFailed(path: String, details: String)

        var logMessage: String {
            switch self {
            case .emptyPath:
                return "Notification custom sound path is empty"
            case .missingFile(let path):
                return "Notification custom sound file does not exist: \(path)"
            case .missingFileExtension(let path):
                return "Notification custom sound requires a file extension: \(path)"
            case .stagingFailed(let path, let details):
                return "Failed to stage custom notification sound from \(path): \(details)"
            }
        }
    }

    static func normalizedPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func expandedURL(for rawPath: String) -> URL? {
        guard let normalized = normalizedPath(rawPath) else { return nil }
        return URL(fileURLWithPath: (normalized as NSString).expandingTildeInPath)
    }

    static func soundDirectoryURL(_ override: URL? = nil) -> URL {
        if let override { return override }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    static func stagedName(
        path: String,
        stagingDirectory: URL? = nil
    ) async -> String? {
        await soundStager.stagedName(
            path: path,
            stagingDirectory: stagingDirectory
        )
    }

    static func stagedNameIfReady(
        path: String,
        stagingDirectory: URL? = nil
    ) async -> String? {
        await soundStager.stagedNameIfReady(
            path: path,
            stagingDirectory: stagingDirectory
        )
    }

    static func prepare(
        path: String,
        stagingDirectory: URL? = nil
    ) async -> Result<String, CustomSoundPreparationIssue> {
        await soundStager.prepareCustomSound(
            path: path,
            stagingDirectory: stagingDirectory
        )
    }

    /// Stages and decodes a picker selection before it is persisted.
    static func validateCustomSoundFileForSelection(
        path: String,
        stagingDirectory: URL? = nil,
        decoder: (@Sendable (URL) -> Bool)? = nil
    ) async -> Bool {
        await soundStager.validateCustomSoundFileForSelection(
            path: path,
            stagingDirectory: stagingDirectory,
            decoder: decoder
        )
    }

    /// Resolves a matrix override and its global fallback through the shared
    /// actor, returning only a playback-ready value to the caller.
    static func prepareNotificationSound(
        snapshot: NotificationSoundResolutionSnapshot,
        stagingDirectory: URL? = nil
    ) async -> PreparedNotificationSound {
        await soundStager.prepareNotificationSound(
            snapshot: snapshot,
            stagingDirectory: stagingDirectory
        )
    }

    static func stageSystemSound(
        value: String,
        sourceDirectory: URL = systemSoundDirectoryURL,
        stagingDirectory: URL? = nil
    ) async -> String? {
        await soundStager.stageSystemSound(
            value: value,
            allowedValues: Set(systemSounds.map { $0.value }),
            sourceDirectory: sourceDirectory,
            stagingDirectory: stagingDirectory
        )
    }

    static func stagedURL(named fileName: String, stagingDirectory: URL? = nil) -> URL {
        soundDirectoryURL(stagingDirectory)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func stagedFileExtension(forSourceExtension sourceExtension: String) -> String {
        let normalized = sourceExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return "caf" }
        return supportedCustomSoundExtensions.contains(normalized) ? normalized : "caf"
    }

    static func stagedFileName(
        forSourceURL sourceURL: URL,
        destinationExtension: String
    ) -> String {
        let normalizedExtension = destinationExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let ext = normalizedExtension.isEmpty ? "caf" : normalizedExtension
        return "\(customSoundBaseName)-\(sourceSignature(for: sourceURL)).\(ext)"
    }

    static func systemSoundFileName(for value: String) -> String {
        "\(systemSoundBaseName)-\(value).aiff"
    }
}
