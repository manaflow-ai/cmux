import AVFoundation
import CmuxFoundation
import CmuxSettings
import Foundation

/// Shared file staging for notification sounds.
///
/// User-selected files cannot be referenced directly by a notification
/// request: the notification daemon reads from the app's Sounds directory and
/// supports a smaller set of codecs than an open panel does. This service
/// owns the deterministic cache, source metadata, and `.m4r` conversion used
/// by both the global picker and sparse per-agent matrix cells.
extension NotificationSoundSettings {
    static let customSoundBaseName = "cmux-custom-notification-sound"
    static let systemSoundBaseName = "cmux-system-notification-sound"
    static let systemSoundDirectoryURL = URL(
        fileURLWithPath: "/System/Library/Sounds",
        isDirectory: true
    )

    private static let preparationQueue = DispatchQueue(
        label: "com.cmuxterm.notification-sound-preparation",
        qos: .utility
    )
    private static let supportedExtensions: Set<String> = [
        "aif",
        "aiff",
        "caf",
        "wav",
    ]

    enum CustomSoundPreparationIssue: Error, Sendable {
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

    static func stagedName(path rawPath: String, stagingDirectory: URL? = nil) -> String? {
        guard let normalized = normalizedPath(rawPath) else {
            NSLog("Notification custom sound unavailable: \(CustomSoundPreparationIssue.emptyPath.logMessage)")
            return nil
        }
        guard let sourceURL = expandedURL(for: normalized) else { return nil }
        let sourceExtension = sourceURL.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !sourceExtension.isEmpty else {
            NSLog(
                "Notification custom sound unavailable: "
                    + CustomSoundPreparationIssue.missingFileExtension(path: sourceURL.path).logMessage
            )
            return nil
        }

        let destinationExtension = stagedFileExtension(forSourceExtension: sourceExtension)
        let stagedFileName = stagedFileName(
            forSourceURL: sourceURL,
            destinationExtension: destinationExtension
        )
        let stagedURL = soundDirectoryURL(stagingDirectory)
            .appendingPathComponent(stagedFileName, isDirectory: false)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            NSLog(
                "Notification custom sound unavailable: "
                    + CustomSoundPreparationIssue.missingFile(path: sourceURL.path).logMessage
            )
            return nil
        }

        if fileManager.fileExists(atPath: stagedURL.path),
           let sourceMetadata = currentMetadata(for: sourceURL, fileManager: fileManager),
           let stagedMetadata = loadMetadata(for: stagedURL),
           stagedMetadata == sourceMetadata {
            return stagedFileName
        }

        switch prepare(path: normalized, stagingDirectory: stagingDirectory) {
        case .success(let preparedName):
            return preparedName
        case .failure(let issue):
            NSLog("Notification custom sound unavailable: \(issue.logMessage)")
            return nil
        }
    }

    /// Returns a prepared artifact without copying or transcoding the source.
    ///
    /// Notification content is often assembled on the main actor.  That path
    /// must never invoke `afconvert`, so it uses this ready-only lookup and
    /// falls back to the global sound when selection-time preparation has not
    /// produced a current artifact yet.
    static func stagedNameIfReady(
        path rawPath: String,
        stagingDirectory: URL? = nil
    ) -> String? {
        guard let normalized = normalizedPath(rawPath),
              let sourceURL = expandedURL(for: normalized) else {
            return nil
        }
        let sourceExtension = sourceURL.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !sourceExtension.isEmpty else { return nil }

        let destinationExtension = stagedFileExtension(forSourceExtension: sourceExtension)
        let stagedFileName = stagedFileName(
            forSourceURL: sourceURL,
            destinationExtension: destinationExtension
        )
        let stagedURL = stagedURL(named: stagedFileName, stagingDirectory: stagingDirectory)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path),
              fileManager.fileExists(atPath: stagedURL.path),
              let sourceMetadata = currentMetadata(for: sourceURL, fileManager: fileManager),
              loadMetadata(for: stagedURL) == sourceMetadata else {
            return nil
        }
        return stagedFileName
    }

    static func prepare(
        path rawPath: String,
        stagingDirectory: URL? = nil
    ) -> Result<String, CustomSoundPreparationIssue> {
        guard let normalized = normalizedPath(rawPath) else {
            return .failure(.emptyPath)
        }
        guard let sourceURL = expandedURL(for: normalized) else {
            return .failure(.emptyPath)
        }
        return prepare(
            from: sourceURL,
            destinationDirectory: soundDirectoryURL(stagingDirectory)
        )
    }

    /// Prepares and decodes a picker selection on the utility queue.
    static func validateCustomSoundFileForSelection(
        path: String,
        stagingDirectory: URL? = nil,
        decoder: (@Sendable (URL) -> Bool)? = nil
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            preparationQueue.async {
                let result = prepare(path: path, stagingDirectory: stagingDirectory)
                guard case .success(let stagedName) = result else {
                    continuation.resume(returning: false)
                    return
                }
                let stagedURL = stagedURL(
                    named: stagedName,
                    stagingDirectory: stagingDirectory
                )
                let fileManager = FileManager.default
                let isDecodable = decoder?(stagedURL)
                    ?? isDecodableSoundFile(at: stagedURL)
                continuation.resume(returning:
                    !stagedName.isEmpty
                        && fileManager.fileExists(atPath: stagedURL.path)
                        && isDecodable
                )
            }
        }
    }

    /// Resolves fallback and prepares a complete sound on the utility queue.
    static func prepareNotificationSound(
        snapshot: NotificationSoundResolutionSnapshot,
        stagingDirectory: URL? = nil
    ) async -> PreparedNotificationSound {
        await withCheckedContinuation { continuation in
            preparationQueue.async {
                continuation.resume(returning: prepareNotificationSoundSynchronously(
                    snapshot: snapshot,
                    stagingDirectory: stagingDirectory
                ))
            }
        }
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
        return supportedExtensions.contains(normalized) ? normalized : "caf"
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

    static func stagedSystemSoundName(
        for value: String,
        allowedValues: [(label: String, value: String)],
        fileManager: FileManager = .default,
        sourceDirectory: URL = systemSoundDirectoryURL,
        stagingDirectory: URL? = nil
    ) -> String? {
        guard allowedValues.contains(where: {
            $0.value == value && value != "default" && value != "custom_file" && value != "none"
        }) else {
            return nil
        }

        let sourceURL = sourceDirectory.appendingPathComponent(
            "\(value).aiff",
            isDirectory: false
        )
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }

        let destinationDirectory = soundDirectoryURL(stagingDirectory)
        let destinationFileName = systemSoundFileName(for: value)
        let destinationURL = destinationDirectory.appendingPathComponent(
            destinationFileName,
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
            try copyIfNeeded(from: sourceURL, to: destinationURL, fileManager: fileManager)
            return destinationFileName
        } catch {
            NSLog("Failed to stage notification system sound \(value): \(error.localizedDescription)")
            return nil
        }
    }

    private static func prepare(
        from sourceURL: URL,
        destinationDirectory: URL
    ) -> Result<String, CustomSoundPreparationIssue> {
        let sourcePath = sourceURL.path
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourcePath) else {
            return .failure(.missingFile(path: sourcePath))
        }
        let sourceExtension = sourceURL.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceExtension.isEmpty else {
            return .failure(.missingFileExtension(path: sourcePath))
        }

        let destinationExtension = stagedFileExtension(forSourceExtension: sourceExtension)
        let destinationFileName = stagedFileName(
            forSourceURL: sourceURL,
            destinationExtension: destinationExtension
        )
        let destinationURL = destinationDirectory.appendingPathComponent(
            destinationFileName,
            isDirectory: false
        )
        let sourceMetadata = currentMetadata(for: sourceURL, fileManager: fileManager)

        do {
            try fileManager.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destinationURL.path) {
                let stagedMetadata = loadMetadata(for: destinationURL)
                if stagedMetadata != sourceMetadata {
                    try? fileManager.removeItem(at: destinationURL)
                }
            }
            if destinationExtension == sourceExtension.lowercased() {
                try copyIfNeeded(from: sourceURL, to: destinationURL, fileManager: fileManager)
            } else {
                try transcodeIfNeeded(from: sourceURL, to: destinationURL, fileManager: fileManager)
            }
            if let sourceMetadata {
                try saveMetadata(sourceMetadata, for: destinationURL)
            }
            // Do not delete other managed files: matrix cells intentionally
            // keep independent cache entries alive at the same time.
            return .success(destinationFileName)
        } catch {
            return .failure(.stagingFailed(path: sourcePath, details: error.localizedDescription))
        }
    }

    private static func copyIfNeeded(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        let normalizedSource = sourceURL.standardizedFileURL
        let normalizedDestination = destinationURL.standardizedFileURL
        guard normalizedSource != normalizedDestination else { return }

        if fileManager.fileExists(atPath: normalizedDestination.path) {
            let sourceAttributes = try fileManager.attributesOfItem(atPath: normalizedSource.path)
            let destinationAttributes = try fileManager.attributesOfItem(atPath: normalizedDestination.path)
            let sourceSize = sourceAttributes[.size] as? NSNumber
            let destinationSize = destinationAttributes[.size] as? NSNumber
            let sourceDate = sourceAttributes[.modificationDate] as? Date
            let destinationDate = destinationAttributes[.modificationDate] as? Date
            if sourceSize == destinationSize && sourceDate == destinationDate { return }
            try fileManager.removeItem(at: normalizedDestination)
        }

        do {
            try fileManager.copyItem(at: normalizedSource, to: normalizedDestination)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileWriteFileExistsError,
               fileManager.fileExists(atPath: normalizedDestination.path) {
                return
            }
            throw error
        }
    }

    private static func transcodeIfNeeded(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        let normalizedSource = sourceURL.standardizedFileURL
        let normalizedDestination = destinationURL.standardizedFileURL
        guard normalizedSource != normalizedDestination else { return }

        if fileManager.fileExists(atPath: normalizedDestination.path) {
            let sourceAttributes = try fileManager.attributesOfItem(atPath: normalizedSource.path)
            let destinationAttributes = try fileManager.attributesOfItem(atPath: normalizedDestination.path)
            let sourceDate = sourceAttributes[.modificationDate] as? Date
            let destinationDate = destinationAttributes[.modificationDate] as? Date
            if let sourceDate, let destinationDate, destinationDate >= sourceDate { return }
            try fileManager.removeItem(at: normalizedDestination)
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            "-f", "caff",
            "-d", "LEI16",
            normalizedSource.path,
            normalizedDestination.path,
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            let errorOutput = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if fileManager.fileExists(atPath: normalizedDestination.path) {
                try? fileManager.removeItem(at: normalizedDestination)
            }
            let description = errorOutput.flatMap { $0.isEmpty ? nil : $0 }
                ?? "afconvert failed with exit code \(process.terminationStatus)"
            throw NSError(
                domain: "NotificationSoundSettings",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }
    }

    private static func prepareNotificationSoundSynchronously(
        snapshot: NotificationSoundResolutionSnapshot,
        stagingDirectory: URL?
    ) -> PreparedNotificationSound {
        if let overrideSelection = snapshot.overrideSelection,
           let preparedOverride = prepareSelection(
               overrideSelection,
               stagingDirectory: stagingDirectory
           ) {
            return preparedOverride
        }
        if let preparedGlobal = prepareSelection(
            snapshot.globalSelection,
            stagingDirectory: stagingDirectory
        ) {
            return preparedGlobal
        }
        if snapshot.globalSelection.value == NotificationSoundOverride.customFileValue {
            // Preserve the existing global custom-file behavior: an unavailable
            // global file is silent. Only a failed matrix cell falls back.
            return .silent
        }
        return .systemDefault
    }

    private static func prepareSelection(
        _ selection: ResolvedNotificationSoundPlaybackSelection,
        stagingDirectory: URL?
    ) -> PreparedNotificationSound? {
        switch selection.value {
        case NotificationSoundOverride.defaultValue:
            return .systemDefault
        case NotificationSoundOverride.noneValue:
            return .silent
        case NotificationSoundOverride.customFileValue:
            guard let path = selection.customFilePath,
                  let sourceURL = expandedURL(for: path),
                  FileManager.default.fileExists(atPath: sourceURL.path),
                  case .success(let stagedName) = prepare(
                      path: path,
                      stagingDirectory: stagingDirectory
                  ) else {
                return nil
            }
            let stagedURL = stagedURL(
                named: stagedName,
                stagingDirectory: stagingDirectory
            )
            guard FileManager.default.fileExists(atPath: sourceURL.path),
                  isDecodableSoundFile(at: stagedURL) else {
                return nil
            }
            return .named(stagedName)
        default:
            guard NotificationSoundOverride.isValidSoundValue(selection.value),
                  let stagedName = stagedSystemSoundName(
                      for: selection.value,
                      stagingDirectory: stagingDirectory
                  ) else {
                return nil
            }
            return .named(stagedName)
        }
    }

    private static func isDecodableSoundFile(at url: URL) -> Bool {
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0,
                  file.processingFormat.channelCount > 0,
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: file.processingFormat,
                      frameCapacity: 1
                  ) else {
                return false
            }
            try file.read(into: buffer, frameCount: 1)
            return buffer.frameLength == 1
        } catch {
            return false
        }
    }
}
