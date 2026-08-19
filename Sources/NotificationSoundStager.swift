import AVFoundation
import CmuxFoundation
import CmuxSettings
import Foundation
import os

nonisolated private let notificationSoundStagerLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "notification-sound"
)

/// Gives a cancellation handler a Sendable way to terminate an `afconvert`
/// process without capturing the Foundation process directly in a concurrent
/// closure.
/// Sole owner of notification-sound staging artifacts.
///
/// Actor isolation serializes every managed-file write, including metadata
/// sidecars and `.m4r` transcoding. Conversion suspends while `afconvert`
/// reports termination, so the actor remains available to other callers while
/// each transaction still commits its artifact serially.
actor NotificationSoundStager {
    typealias PreparationIssue = NotificationSoundSettings.CustomSoundPreparationIssue
    private let processRunner = NotificationSoundProcessRunner()
    private var inFlightConversions: [URL: Task<NotificationSoundProcessRunner.Result, Error>] = [:]

    func stagedName(
        path rawPath: String,
        stagingDirectory: URL?
    ) async -> String? {
        guard let normalized = NotificationSoundSettings.normalizedPath(rawPath) else {
            log(.emptyPath)
            return nil
        }
        guard let sourceURL = NotificationSoundSettings.expandedURL(for: normalized) else {
            log(.emptyPath)
            return nil
        }
        let sourceExtension = sourceURL.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !sourceExtension.isEmpty else {
            log(.missingFileExtension(path: sourceURL.path))
            return nil
        }

        let destinationExtension = NotificationSoundSettings.stagedFileExtension(
            forSourceExtension: sourceExtension
        )
        let stagedFileName = NotificationSoundSettings.stagedFileName(
            forSourceURL: sourceURL,
            destinationExtension: destinationExtension
        )
        let stagedURL = NotificationSoundSettings.stagedURL(
            named: stagedFileName,
            stagingDirectory: stagingDirectory
        )
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            log(.missingFile(path: sourceURL.path))
            return nil
        }

        if isCurrentArtifact(
            sourceURL: sourceURL,
            stagedURL: stagedURL,
            fileManager: fileManager
        ) {
            return stagedFileName
        }

        switch await prepareCustomSound(path: normalized, stagingDirectory: stagingDirectory) {
        case .success(let preparedName):
            return preparedName
        case .failure(let issue):
            log(issue)
            return nil
        }
    }

    /// Returns an existing current artifact without copying or transcoding.
    func stagedNameIfReady(
        path rawPath: String,
        stagingDirectory: URL?
    ) -> String? {
        guard let normalized = NotificationSoundSettings.normalizedPath(rawPath),
              let sourceURL = NotificationSoundSettings.expandedURL(for: normalized) else {
            return nil
        }
        let sourceExtension = sourceURL.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !sourceExtension.isEmpty else { return nil }

        let destinationExtension = NotificationSoundSettings.stagedFileExtension(
            forSourceExtension: sourceExtension
        )
        let stagedFileName = NotificationSoundSettings.stagedFileName(
            forSourceURL: sourceURL,
            destinationExtension: destinationExtension
        )
        let stagedURL = NotificationSoundSettings.stagedURL(
            named: stagedFileName,
            stagingDirectory: stagingDirectory
        )
        return isCurrentArtifact(
            sourceURL: sourceURL,
            stagedURL: stagedURL,
            fileManager: .default
        ) ? stagedFileName : nil
    }

    func prepareCustomSound(
        path rawPath: String,
        stagingDirectory: URL?
    ) async -> Result<String, PreparationIssue> {
        guard let normalized = NotificationSoundSettings.normalizedPath(rawPath),
              let sourceURL = NotificationSoundSettings.expandedURL(for: normalized) else {
            return .failure(.emptyPath)
        }
        return await prepareCustomSound(
            from: sourceURL,
            destinationDirectory: NotificationSoundSettings.soundDirectoryURL(stagingDirectory)
        )
    }

    func validateCustomSoundFileForSelection(
        path: String,
        stagingDirectory: URL?,
        decoder: (@Sendable (URL) -> Bool)?
    ) async -> Bool {
        let result = await prepareCustomSound(
            path: path,
            stagingDirectory: stagingDirectory
        )
        guard case .success(let stagedName) = result else { return false }
        let stagedURL = NotificationSoundSettings.stagedURL(
            named: stagedName,
            stagingDirectory: stagingDirectory
        )
        let fileManager = FileManager.default
        let isDecodable = decoder?(stagedURL) ?? isDecodableSoundFile(at: stagedURL)
        return !stagedName.isEmpty
            && fileManager.fileExists(atPath: stagedURL.path)
            && isDecodable
    }

    func prepareNotificationSound(
        snapshot: NotificationSoundResolutionSnapshot,
        stagingDirectory: URL?
    ) async -> PreparedNotificationSound {
        if let overrideSelection = snapshot.overrideSelection,
           let preparedOverride = await prepareSelection(
               overrideSelection,
               stagingDirectory: stagingDirectory
           ) {
            return preparedOverride
        }
        if let preparedGlobal = await prepareSelection(
            snapshot.globalSelection,
            stagingDirectory: stagingDirectory
        ) {
            return preparedGlobal
        }
        if snapshot.globalSelection.value == NotificationSoundOverride.customFileValue {
            // Preserve global custom-file behavior: a missing global file is
            // silent. Only a missing matrix override falls back globally.
            return .silent
        }
        return .systemDefault
    }

    func stageSystemSound(
        value: String,
        allowedValues: Set<String>,
        sourceDirectory: URL,
        stagingDirectory: URL?
    ) -> String? {
        guard allowedValues.contains(value),
              value != NotificationSoundOverride.defaultValue,
              value != NotificationSoundOverride.customFileValue,
              value != NotificationSoundOverride.noneValue else {
            return nil
        }

        let fileManager = FileManager.default
        let sourceURL = sourceDirectory.appendingPathComponent(
            "\(value).aiff",
            isDirectory: false
        )
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }

        let destinationDirectory = NotificationSoundSettings.soundDirectoryURL(stagingDirectory)
        let destinationFileName = NotificationSoundSettings.systemSoundFileName(for: value)
        let destinationURL = destinationDirectory.appendingPathComponent(
            destinationFileName,
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
            try copyIfNeeded(
                from: sourceURL,
                to: destinationURL,
                fileManager: fileManager
            )
            return destinationFileName
        } catch {
            notificationSoundStagerLogger.error(
                "Failed to stage notification system sound \(value, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    private func prepareSelection(
        _ selection: ResolvedNotificationSoundPlaybackSelection,
        stagingDirectory: URL?
    ) async -> PreparedNotificationSound? {
        switch selection.value {
        case NotificationSoundOverride.defaultValue:
            return .systemDefault
        case NotificationSoundOverride.noneValue:
            return .silent
        case NotificationSoundOverride.customFileValue:
            guard let path = selection.customFilePath,
                  let sourceURL = NotificationSoundSettings.expandedURL(for: path),
                  FileManager.default.fileExists(atPath: sourceURL.path),
                  case .success(let stagedName) = await prepareCustomSound(
                      path: path,
                      stagingDirectory: stagingDirectory
                  ) else {
                return nil
            }
            let stagedURL = NotificationSoundSettings.stagedURL(
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
                  let stagedName = stageSystemSound(
                      value: selection.value,
                      allowedValues: Set(NotificationSoundSettings.systemSounds.map { $0.value }),
                      sourceDirectory: NotificationSoundSettings.systemSoundDirectoryURL,
                      stagingDirectory: stagingDirectory
                  ) else {
                return nil
            }
            return .named(stagedName)
        }
    }

    private func prepareCustomSound(
        from sourceURL: URL,
        destinationDirectory: URL
    ) async -> Result<String, PreparationIssue> {
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

        let destinationExtension = NotificationSoundSettings.stagedFileExtension(
            forSourceExtension: sourceExtension
        )
        let destinationFileName = NotificationSoundSettings.stagedFileName(
            forSourceURL: sourceURL,
            destinationExtension: destinationExtension
        )
        let destinationURL = destinationDirectory.appendingPathComponent(
            destinationFileName,
            isDirectory: false
        )
        let sourceMetadata = NotificationSoundSettings.currentMetadata(
            for: sourceURL,
            fileManager: fileManager
        )

        do {
            try fileManager.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destinationURL.path),
               NotificationSoundSettings.loadMetadata(for: destinationURL) != sourceMetadata {
                try? fileManager.removeItem(at: destinationURL)
            }
            if destinationExtension == sourceExtension.lowercased() {
                try copyIfNeeded(
                    from: sourceURL,
                    to: destinationURL,
                    fileManager: fileManager
                )
            } else {
                try await transcodeIfNeeded(
                    from: sourceURL,
                    to: destinationURL,
                    fileManager: fileManager
                )
            }
            if let sourceMetadata {
                try NotificationSoundSettings.saveMetadata(
                    sourceMetadata,
                    for: destinationURL
                )
            }
            // Matrix cells intentionally keep independent cache entries alive.
            return .success(destinationFileName)
        } catch {
            return .failure(.stagingFailed(
                path: sourcePath,
                details: error.localizedDescription
            ))
        }
    }

    private func isCurrentArtifact(
        sourceURL: URL,
        stagedURL: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: sourceURL.path),
              fileManager.fileExists(atPath: stagedURL.path),
              let sourceMetadata = NotificationSoundSettings.currentMetadata(
                  for: sourceURL,
                  fileManager: fileManager
              ),
              NotificationSoundSettings.loadMetadata(for: stagedURL) == sourceMetadata else {
            return false
        }
        return true
    }

    private func copyIfNeeded(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        guard source != destination else { return }

        if fileManager.fileExists(atPath: destination.path) {
            let sourceAttributes = try fileManager.attributesOfItem(atPath: source.path)
            let destinationAttributes = try fileManager.attributesOfItem(atPath: destination.path)
            let sourceSize = sourceAttributes[.size] as? NSNumber
            let destinationSize = destinationAttributes[.size] as? NSNumber
            let sourceDate = sourceAttributes[.modificationDate] as? Date
            let destinationDate = destinationAttributes[.modificationDate] as? Date
            if sourceSize == destinationSize, sourceDate == destinationDate { return }
            try fileManager.removeItem(at: destination)
        }

        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileWriteFileExistsError,
               fileManager.fileExists(atPath: destination.path) {
                return
            }
            throw error
        }
    }

    private func transcodeIfNeeded(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) async throws {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        guard source != destination else { return }

        // A conversion may create its destination before it terminates. Join
        // an existing transaction before inspecting that file so another
        // caller never decodes a partially written artifact.
        if let existing = inFlightConversions[destination] {
            let result = try await existing.value
            try validateConversionResult(
                result,
                destination: destination,
                fileManager: fileManager
            )
            return
        }

        if fileManager.fileExists(atPath: destination.path) {
            let sourceAttributes = try fileManager.attributesOfItem(atPath: source.path)
            let destinationAttributes = try fileManager.attributesOfItem(atPath: destination.path)
            let sourceDate = sourceAttributes[.modificationDate] as? Date
            let destinationDate = destinationAttributes[.modificationDate] as? Date
            if let sourceDate, let destinationDate, destinationDate >= sourceDate { return }
            try fileManager.removeItem(at: destination)
        }

        let processRunner = self.processRunner
        let conversionTask = Task.detached {
            try await processRunner.run(from: source, to: destination)
        }
        inFlightConversions[destination] = conversionTask
        defer { inFlightConversions.removeValue(forKey: destination) }

        let result = try await conversionTask.value
        try validateConversionResult(
            result,
            destination: destination,
            fileManager: fileManager
        )
    }

    private func validateConversionResult(
        _ result: NotificationSoundProcessRunner.Result,
        destination: URL,
        fileManager: FileManager
    ) throws {
        guard result.terminationStatus == 0 else {
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            let description = result.errorOutput
                ?? "afconvert failed with exit code \(result.terminationStatus)"
            throw NSError(
                domain: "NotificationSoundSettings",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }
    }

    private func isDecodableSoundFile(at url: URL) -> Bool {
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

    private func log(_ issue: PreparationIssue) {
        notificationSoundStagerLogger.error(
            "Notification custom sound unavailable: \(issue.logMessage, privacy: .private)"
        )
    }
}
