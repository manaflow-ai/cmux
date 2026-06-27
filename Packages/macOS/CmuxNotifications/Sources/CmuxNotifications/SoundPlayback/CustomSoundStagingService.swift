public import Foundation
import CmuxFoundation

/// Stages notification sound files into `~/Library/Sounds` so the user
/// notification framework can resolve them by name.
///
/// `UNNotificationSound(named:)` can only name a file already present in
/// `~/Library/Sounds`, so both the bundled macOS system sounds and a
/// user-chosen custom file must be copied (or transcoded with `afconvert`)
/// into that directory under a deterministic, content-addressed name. This
/// service owns that file-staging engine: copy/transcode, source-metadata
/// sidecars used to skip redundant work, stale-file cleanup, and background
/// dedup of in-flight custom-file preparation.
///
/// A single instance must back the whole process so the in-flight dedup set is
/// shared across every caller. The dedup set is guarded by an `NSLock` rather
/// than an actor on purpose: ``stagedCustomSoundName(rawPath:)`` runs
/// synchronously off the notification path and schedules background
/// preparation on a utility queue without `await`, so the guard must be a
/// plain lock around a tiny value. Lifted byte-identically from the former
/// `NotificationSoundSettings` static custom/system sound-staging members.
public final class CustomSoundStagingService: @unchecked Sendable {
    private let stagedCustomSoundBaseName = "cmux-custom-notification-sound"
    private let customSoundPreparationQueue = DispatchQueue(
        label: "com.cmuxterm.notification-sound-preparation",
        qos: .utility
    )
    private let systemSoundBaseName = "cmux-system-notification-sound"
    // `pendingCustomSoundPreparationPaths` is guarded by
    // `pendingCustomSoundPreparationLock`.
    private let pendingCustomSoundPreparationLock = NSLock()
    private var pendingCustomSoundPreparationPaths: Set<String> = []
    private let notificationSoundSupportedExtensions: Set<String> = [
        "aif",
        "aiff",
        "caf",
        "wav",
    ]

    /// Creates a staging service. A single instance must back the whole
    /// process so the in-flight custom-file dedup set is shared.
    public init() {}

    private struct CustomSoundSourceMetadata: Codable, Equatable {
        let sourcePath: String
        let sourceSize: UInt64
        let sourceModificationTime: Double
        let sourceFileIdentifier: UInt64?
    }

    /// Returns the staged file name for the custom sound at `rawPath` (the
    /// user-configured path, before normalization), staging or transcoding it
    /// into `~/Library/Sounds` when needed. Returns `nil` when the source is
    /// empty/missing or is being prepared in the background.
    public func stagedCustomSoundName(rawPath: String) -> String? {
        guard let normalizedPath = normalizedFilePath(rawPath) else {
            NSLog("Notification custom sound unavailable: \(CustomSoundPreparationIssue.emptyPath.logMessage)")
            return nil
        }

        let sourceURL = URL(fileURLWithPath: (normalizedPath as NSString).expandingTildeInPath)
        let sourceExtension = sourceURL.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !sourceExtension.isEmpty else {
            NSLog("Notification custom sound unavailable: \(CustomSoundPreparationIssue.missingFileExtension(path: sourceURL.path).logMessage)")
            return nil
        }

        let destinationExtension = stagedCustomSoundFileExtension(forSourceExtension: sourceExtension)
        let stagedFileName = stagedCustomSoundFileName(
            forSourceURL: sourceURL,
            destinationExtension: destinationExtension
        )
        let stagedURL = stagedSoundDirectoryURL().appendingPathComponent(stagedFileName, isDirectory: false)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            NSLog("Notification custom sound unavailable: \(CustomSoundPreparationIssue.missingFile(path: sourceURL.path).logMessage)")
            return nil
        }

        if fileManager.fileExists(atPath: stagedURL.path) {
            if let sourceMetadata = currentSourceMetadata(for: sourceURL, fileManager: fileManager),
               let stagedMetadata = loadStagedSourceMetadata(for: stagedURL),
               stagedMetadata == sourceMetadata {
                return stagedFileName
            }
        }

        if destinationExtension == sourceExtension {
            switch prepareCustomFile(path: normalizedPath) {
            case .success(let preparedName):
                return preparedName
            case .failure(let issue):
                NSLog("Notification custom sound unavailable: \(issue.logMessage)")
                return nil
            }
        }

        queueCustomSoundPreparation(path: normalizedPath)
        NSLog("Notification custom sound not ready yet, staging in background: \(sourceURL.path)")
        return nil
    }

    /// Stages the custom sound file at `path` into `~/Library/Sounds`,
    /// returning the staged file name or the failure encountered.
    public func prepareCustomFile(path: String) -> Result<String, CustomSoundPreparationIssue> {
        guard let normalizedPath = normalizedFilePath(path) else {
            return .failure(.emptyPath)
        }
        let sourceURL = URL(fileURLWithPath: (normalizedPath as NSString).expandingTildeInPath)
        return prepareCustomSound(from: sourceURL)
    }

    private func prepareCustomSound(from sourceURL: URL) -> Result<String, CustomSoundPreparationIssue> {
        let sourcePath = sourceURL.path
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourcePath) else {
            return .failure(.missingFile(path: sourcePath))
        }
        let sourceExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceExtension.isEmpty else {
            return .failure(.missingFileExtension(path: sourcePath))
        }
        let destinationExtension = stagedCustomSoundFileExtension(forSourceExtension: sourceExtension)

        let destinationDirectory = stagedSoundDirectoryURL()
        let destinationFileName = stagedCustomSoundFileName(
            forSourceURL: sourceURL,
            destinationExtension: destinationExtension
        )
        let destinationURL = destinationDirectory.appendingPathComponent(destinationFileName, isDirectory: false)
        let sourceMetadata = currentSourceMetadata(for: sourceURL, fileManager: fileManager)

        do {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationURL.path) {
                let stagedMetadata = loadStagedSourceMetadata(for: destinationURL)
                if stagedMetadata != sourceMetadata {
                    try? fileManager.removeItem(at: destinationURL)
                }
            }
            if destinationExtension == sourceExtension.lowercased() {
                try copyStagedSoundIfNeeded(from: sourceURL, to: destinationURL, fileManager: fileManager)
            } else {
                try transcodeStagedSoundIfNeeded(from: sourceURL, to: destinationURL, fileManager: fileManager)
            }
            if let sourceMetadata {
                try saveStagedSourceMetadata(sourceMetadata, for: destinationURL)
            }
            try cleanupStaleStagedSoundFiles(
                in: destinationDirectory,
                keeping: destinationFileName,
                preservingSourceURL: sourceURL,
                fileManager: fileManager
            )
            return .success(destinationFileName)
        } catch {
            return .failure(.stagingFailed(path: sourcePath, details: error.localizedDescription))
        }
    }

    /// The staged file name used for the named macOS system sound `value`.
    public func stagedSystemSoundFileName(for value: String) -> String {
        "\(systemSoundBaseName)-\(value).aiff"
    }

    /// Stages the named macOS system sound `value` (read from `sourceDirectory`,
    /// e.g. `/System/Library/Sounds`) into the staging directory and returns
    /// the staged file name, or `nil` when the source is missing or staging
    /// fails. The caller is responsible for confirming `value` is a stageable
    /// system sound before calling this.
    public func stageSystemSound(
        for value: String,
        fileManager: FileManager = .default,
        sourceDirectory: URL,
        stagingDirectory: URL? = nil
    ) -> String? {
        let sourceURL = sourceDirectory.appendingPathComponent("\(value).aiff", isDirectory: false)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return nil
        }

        let destinationDirectory = stagedSoundDirectoryURL(stagingDirectory)
        let destinationFileName = stagedSystemSoundFileName(for: value)
        let destinationURL = destinationDirectory.appendingPathComponent(destinationFileName, isDirectory: false)
        do {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            try copyStagedSoundIfNeeded(from: sourceURL, to: destinationURL, fileManager: fileManager)
            return destinationFileName
        } catch {
            NSLog("Failed to stage notification system sound \(value): \(error.localizedDescription)")
            return nil
        }
    }

    /// The staged-file extension to use for a custom source extension:
    /// supported extensions are kept; everything else transcodes to `caf`.
    public func stagedCustomSoundFileExtension(forSourceExtension sourceExtension: String) -> String {
        let normalized = sourceExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return "caf" }
        if notificationSoundSupportedExtensions.contains(normalized) {
            return normalized
        }
        return "caf"
    }

    /// The content-addressed staged file name for the custom sound at
    /// `sourceURL` with the given destination extension.
    public func stagedCustomSoundFileName(forSourceURL sourceURL: URL, destinationExtension: String) -> String {
        let normalizedExtension = destinationExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let ext = normalizedExtension.isEmpty ? "caf" : normalizedExtension
        let signature = stagedCustomSoundSourceSignature(for: sourceURL)
        return "\(stagedCustomSoundBaseName)-\(signature).\(ext)"
    }

    private func normalizedFilePath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func stagedSoundDirectoryURL(_ override: URL? = nil) -> URL {
        if let override {
            return override
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    private func queueCustomSoundPreparation(path: String) {
        let expandedPath = (path as NSString).expandingTildeInPath
        pendingCustomSoundPreparationLock.lock()
        if pendingCustomSoundPreparationPaths.contains(expandedPath) {
            pendingCustomSoundPreparationLock.unlock()
            return
        }
        pendingCustomSoundPreparationPaths.insert(expandedPath)
        pendingCustomSoundPreparationLock.unlock()

        customSoundPreparationQueue.async { [self] in
            defer {
                pendingCustomSoundPreparationLock.lock()
                pendingCustomSoundPreparationPaths.remove(expandedPath)
                pendingCustomSoundPreparationLock.unlock()
            }
            _ = prepareCustomFile(path: expandedPath)
        }
    }

    private func cleanupStaleStagedSoundFiles(
        in directoryURL: URL,
        keeping fileName: String,
        preservingSourceURL: URL,
        fileManager: FileManager
    ) throws {
        let legacyPrefix = "\(stagedCustomSoundBaseName)."
        let hashedPrefix = "\(stagedCustomSoundBaseName)-"
        let normalizedSource = preservingSourceURL.standardizedFileURL
        let keptStagedURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        let keptMetadataFileName = stagedSourceMetadataURL(for: keptStagedURL).lastPathComponent
        for fileNameCandidate in try fileManager.contentsOfDirectory(atPath: directoryURL.path) {
            let isManagedName = fileNameCandidate.hasPrefix(legacyPrefix) || fileNameCandidate.hasPrefix(hashedPrefix)
            let isKeptManagedFile = fileNameCandidate == fileName || fileNameCandidate == keptMetadataFileName
            guard isManagedName, !isKeptManagedFile else { continue }
            let staleURL = directoryURL.appendingPathComponent(fileNameCandidate, isDirectory: false)
            if staleURL.standardizedFileURL == normalizedSource {
                continue
            }
            try? fileManager.removeItem(at: staleURL)
            try? fileManager.removeItem(at: stagedSourceMetadataURL(for: staleURL))
        }
    }

    private func copyStagedSoundIfNeeded(
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
            if sourceSize == destinationSize && sourceDate == destinationDate {
                return
            }
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

    private func transcodeStagedSoundIfNeeded(
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
            if let sourceDate, let destinationDate, destinationDate >= sourceDate {
                return
            }
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
            let description: String
            if let errorOutput, !errorOutput.isEmpty {
                description = errorOutput
            } else {
                description = "afconvert failed with exit code \(process.terminationStatus)"
            }
            throw NSError(
                domain: "NotificationSoundSettings",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: description,
                ]
            )
        }
    }

    private func stagedCustomSoundSourceSignature(for sourceURL: URL) -> String {
        let normalizedPath = sourceURL.standardizedFileURL.path
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in normalizedPath.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private func stagedSourceMetadataURL(for stagedURL: URL) -> URL {
        stagedURL.appendingPathExtension("source-metadata")
    }

    private func currentSourceMetadata(for sourceURL: URL, fileManager: FileManager) -> CustomSoundSourceMetadata? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path) else {
            return nil
        }
        guard let sourceSizeNumber = attributes[.size] as? NSNumber else {
            return nil
        }
        let sourceDate = (attributes[.modificationDate] as? Date) ?? .distantPast
        let fileIdentifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        return CustomSoundSourceMetadata(
            sourcePath: sourceURL.standardizedFileURL.path,
            sourceSize: sourceSizeNumber.uint64Value,
            sourceModificationTime: sourceDate.timeIntervalSinceReferenceDate,
            sourceFileIdentifier: fileIdentifier
        )
    }

    private func loadStagedSourceMetadata(for stagedURL: URL) -> CustomSoundSourceMetadata? {
        let metadataURL = stagedSourceMetadataURL(for: stagedURL)
        guard let data = try? Data(contentsOf: metadataURL) else {
            return nil
        }
        return try? JSONDecoder().decode(CustomSoundSourceMetadata.self, from: data)
    }

    private func saveStagedSourceMetadata(_ metadata: CustomSoundSourceMetadata, for stagedURL: URL) throws {
        let metadataURL = stagedSourceMetadataURL(for: stagedURL)
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }
}
