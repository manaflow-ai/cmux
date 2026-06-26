import AppKit
import CmuxFoundation
import CmuxNotifications
import Foundation
import UserNotifications

// Notification sound selection, custom sound staging, Focus/DND suppression,
// fallback playback, and notification custom-command execution.
// Extracted from TerminalNotificationStore.swift to keep that file within the
// Swift file length budget.

enum NotificationSoundSettings {
    static let key = "notificationSound"
    static let defaultValue = "default"
    static let customFileValue = "custom_file"
    static let customFilePathKey = "notificationSoundCustomFilePath"
    static let defaultCustomFilePath = ""
    private static let stagedCustomSoundBaseName = "cmux-custom-notification-sound"
    private static let customSoundPreparationQueue = DispatchQueue(
        label: "com.cmuxterm.notification-sound-preparation",
        qos: .utility
    )
    private static let systemSoundBaseName = "cmux-system-notification-sound"
    private static let systemSoundDirectoryURL = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
    private static let pendingCustomSoundPreparationLock = NSLock()
    private static var pendingCustomSoundPreparationPaths: Set<String> = []
    private static let activePlaybackSoundsLock = NSLock()
    private static var activePlaybackSounds: [ObjectIdentifier: NSSound] = [:]
    private static let activePlaybackSoundDelegate = ActivePlaybackSoundDelegate()
    private static let dndAssertionQueue = DispatchQueue(
        label: "com.cmuxterm.notification-dnd-assertion",
        qos: .utility
    )
    private static let notificationSoundSupportedExtensions: Set<String> = [
        "aif",
        "aiff",
        "caf",
        "wav",
    ]

    private final class ActivePlaybackSoundDelegate: NSObject, NSSoundDelegate {
        func sound(_ sound: NSSound, didFinishPlaying finishedPlaying: Bool) {
            NotificationSoundSettings.releaseActivePlaybackSound(sound)
        }
    }

    private struct CustomSoundSourceMetadata: Codable, Equatable {
        let sourcePath: String
        let sourceSize: UInt64
        let sourceModificationTime: Double
        let sourceFileIdentifier: UInt64?
    }

    enum CustomSoundPreparationIssue: Error {
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
    static let customCommandKey = "notificationCustomCommand"
    static let defaultCustomCommand = ""

    static let systemSounds: [(label: String, value: String)] = [
        ("Default", "default"),
        ("Basso", "Basso"),
        ("Blow", "Blow"),
        ("Bottle", "Bottle"),
        ("Frog", "Frog"),
        ("Funk", "Funk"),
        ("Glass", "Glass"),
        ("Hero", "Hero"),
        ("Morse", "Morse"),
        ("Ping", "Ping"),
        ("Pop", "Pop"),
        ("Purr", "Purr"),
        ("Sosumi", "Sosumi"),
        ("Submarine", "Submarine"),
        ("Tink", "Tink"),
        ("Custom File...", customFileValue),
        ("None", "none"),
    ]

    static func sound(
        defaults: UserDefaults = .standard,
        systemSoundStagingDirectory: URL? = nil
    ) -> UNNotificationSound? {
        let value = defaults.string(forKey: key) ?? defaultValue
        switch value {
        case "default":
            return .default
        case "none":
            return nil
        case customFileValue:
            guard let customSoundName = stagedCustomSoundName(defaults: defaults) else {
                return nil
            }
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: customSoundName))
        default:
            guard let stagedSystemSoundName = stagedSystemSoundName(
                for: value,
                stagingDirectory: systemSoundStagingDirectory
            ) else {
                NSLog("Notification system sound unavailable, falling back to default: \(value)")
                return .default
            }
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: stagedSystemSoundName))
        }
    }

    static func usesSystemSound(defaults: UserDefaults = .standard) -> Bool {
        let value = defaults.string(forKey: key) ?? defaultValue
        switch value {
        case "none":
            return false
        case customFileValue:
            return customFileURL(defaults: defaults) != nil
        default:
            return true
        }
    }

    static func isSilent(defaults: UserDefaults = .standard) -> Bool {
        return (defaults.string(forKey: key) ?? defaultValue) == "none"
    }

    static func isCustomFileSelected(defaults: UserDefaults = .standard) -> Bool {
        (defaults.string(forKey: key) ?? defaultValue) == customFileValue
    }

    static func stagedCustomSoundName(defaults: UserDefaults = .standard) -> String? {
        let rawPath = defaults.string(forKey: customFilePathKey) ?? defaultCustomFilePath
        guard let normalizedPath = normalizedCustomFilePath(rawPath) else {
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
            switch prepareCustomFileForNotifications(path: normalizedPath) {
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

    static func prepareCustomFileForNotifications(path: String) -> Result<String, CustomSoundPreparationIssue> {
        guard let normalizedPath = normalizedCustomFilePath(path) else {
            return .failure(.emptyPath)
        }
        let sourceURL = URL(fileURLWithPath: (normalizedPath as NSString).expandingTildeInPath)
        return prepareCustomSound(from: sourceURL)
    }

    private static func prepareCustomSound(from sourceURL: URL) -> Result<String, CustomSoundPreparationIssue> {
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

    static func customFileURL(defaults: UserDefaults = .standard) -> URL? {
        guard let path = normalizedCustomFilePath(defaults.string(forKey: customFilePathKey) ?? defaultCustomFilePath) else {
            return nil
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static func playCustomFileSound(defaults: UserDefaults = .standard) {
        guard let url = customFileURL(defaults: defaults) else { return }
        playSoundFile(at: url)
    }

    static func playCustomFileSound(path: String) {
        guard let normalizedPath = normalizedCustomFilePath(path) else { return }
        let url = URL(fileURLWithPath: (normalizedPath as NSString).expandingTildeInPath)
        playSoundFile(at: url)
    }

    /// Live Do Not Disturb assertion store written by the Focus daemon.
    ///
    /// DEBUG builds honor `CMUX_DEBUG_DND_ASSERTIONS_PATH` so a tagged dev app
    /// can be driven end-to-end against fixture files instead of the real
    /// (TCC-protected) store.
    static let defaultAssertionsFileURL: URL = {
#if DEBUG
        if let override = ProcessInfo.processInfo.environment["CMUX_DEBUG_DND_ASSERTIONS_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: false)
        }
#endif
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json", isDirectory: false)
    }()

    /// Whether a macOS Focus / Do Not Disturb mode is currently active.
    ///
    /// The `UNUserNotificationCenter` sound path is gated by the OS for Focus
    /// and per-app authorization. This direct `NSSound` fallback (used when the
    /// system would not deliver the banner) is not, so it otherwise punches
    /// through Focus and through a user who has turned notifications off. A
    /// Focus is active when `storeAssertionRecords` holds at least one
    /// assertion. Fails open: any read or parse error returns `false` so sound
    /// keeps working.
    static func isSuppressedByActiveFocus(
        assertionsFileURL: URL = defaultAssertionsFileURL
    ) -> Bool {
        guard
            let data = try? Data(contentsOf: assertionsFileURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = root["data"] as? [[String: Any]]
        else {
            return false
        }
        return entries.contains { entry in
            if let records = entry["storeAssertionRecords"] as? [Any] {
                return !records.isEmpty
            }
            return false
        }
    }

    /// Plays the user-selected notification sound unless an active macOS
    /// Focus / Do Not Disturb mode should silence it.
    ///
    /// The Focus check reads the assertion store, which is disk I/O, so it
    /// runs on the background assertion queue and playback hops back to the
    /// main queue. The state is read fresh for every play: a cached snapshot
    /// would let the first sound after the user enables a Focus punch
    /// through, which is the exact bug this gate exists to fix. Notification
    /// sounds are low-frequency (cooldown-throttled), so one small file read
    /// per play on a utility queue is cheap.
    ///
    /// `completion` runs on the main queue with whether the sound was allowed
    /// to play. It exists so tests can observe the gate decision; production
    /// callers pass nothing.
    static func playSelectedSound(
        defaults: UserDefaults = .standard,
        assertionsFileURL: URL = defaultAssertionsFileURL,
        completion: ((_ didPlay: Bool) -> Void)? = nil
    ) {
        dndAssertionQueue.async {
            let suppressed = isSuppressedByActiveFocus(assertionsFileURL: assertionsFileURL)
#if DEBUG
            // storeReadable distinguishes "no Focus active" from "assertion
            // store unreadable (no Full Disk Access)", which look identical
            // through the fail-open gate.
            let storeReadable = (try? Data(contentsOf: assertionsFileURL)) != nil
            cmuxDebugLog(
                "notification.sound.focusGate suppressed=\(suppressed ? 1 : 0) storeReadable=\(storeReadable ? 1 : 0)"
            )
#endif
            DispatchQueue.main.async {
                if !suppressed {
                    let value = defaults.string(forKey: key) ?? defaultValue
                    playSound(value: value, defaults: defaults)
                }
                completion?(!suppressed)
            }
        }
    }

    static func previewSound(value: String, defaults: UserDefaults = .standard) {
        playSound(value: value, defaults: defaults)
    }

    static func previewSound(value: String, customFilePath: String, defaults: UserDefaults = .standard) {
        playSound(value: value, defaults: defaults, customFilePath: customFilePath)
    }

    private static func playSound(value: String, defaults: UserDefaults, customFilePath: String? = nil) {
        switch value {
        case "default":
            NSSound.beep()
        case "none":
            break
        case customFileValue:
            if let customFilePath,
               normalizedCustomFilePath(customFilePath) != nil {
                playCustomFileSound(path: customFilePath)
            } else {
                playCustomFileSound(defaults: defaults)
            }
        default:
            playSystemSound(named: value)
        }
    }

    static func stagedSystemSoundFileName(for value: String) -> String {
        "\(systemSoundBaseName)-\(value).aiff"
    }

    static func stagedSystemSoundName(
        for value: String,
        fileManager: FileManager = .default,
        sourceDirectory: URL = systemSoundDirectoryURL,
        stagingDirectory: URL? = nil
    ) -> String? {
        guard systemSounds.contains(where: { option in
            option.value == value && value != defaultValue && value != customFileValue && value != "none"
        }) else {
            return nil
        }

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

    private static func playSystemSound(named value: String) {
        guard let sound = NSSound(named: NSSound.Name(value)) else {
            return
        }
        retainActivePlaybackSound(sound)
        sound.delegate = activePlaybackSoundDelegate
        if !sound.play() {
            releaseActivePlaybackSound(sound)
        }
    }

    static func stagedCustomSoundFileExtension(forSourceExtension sourceExtension: String) -> String {
        let normalized = sourceExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return "caf" }
        if notificationSoundSupportedExtensions.contains(normalized) {
            return normalized
        }
        return "caf"
    }

    static func stagedCustomSoundFileName(forSourceURL sourceURL: URL, destinationExtension: String) -> String {
        let normalizedExtension = destinationExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let ext = normalizedExtension.isEmpty ? "caf" : normalizedExtension
        let signature = stagedCustomSoundSourceSignature(for: sourceURL)
        return "\(stagedCustomSoundBaseName)-\(signature).\(ext)"
    }

    private static func normalizedCustomFilePath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func stagedSoundDirectoryURL(_ override: URL? = nil) -> URL {
        if let override {
            return override
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    private static func queueCustomSoundPreparation(path: String) {
        let expandedPath = (path as NSString).expandingTildeInPath
        pendingCustomSoundPreparationLock.lock()
        if pendingCustomSoundPreparationPaths.contains(expandedPath) {
            pendingCustomSoundPreparationLock.unlock()
            return
        }
        pendingCustomSoundPreparationPaths.insert(expandedPath)
        pendingCustomSoundPreparationLock.unlock()

        customSoundPreparationQueue.async {
            defer {
                pendingCustomSoundPreparationLock.lock()
                pendingCustomSoundPreparationPaths.remove(expandedPath)
                pendingCustomSoundPreparationLock.unlock()
            }
            _ = prepareCustomFileForNotifications(path: expandedPath)
        }
    }

    private static func playSoundFile(at url: URL) {
        DispatchQueue.main.async {
            guard let sound = NSSound(contentsOf: url, byReference: false) else {
                NSLog("Notification custom sound failed to load from path: \(url.path)")
                return
            }
            retainActivePlaybackSound(sound)
            sound.delegate = activePlaybackSoundDelegate
            if !sound.play() {
                releaseActivePlaybackSound(sound)
            }
        }
    }

    private static func retainActivePlaybackSound(_ sound: NSSound) {
        activePlaybackSoundsLock.lock()
        activePlaybackSounds[ObjectIdentifier(sound)] = sound
        activePlaybackSoundsLock.unlock()
    }

    private static func releaseActivePlaybackSound(_ sound: NSSound) {
        activePlaybackSoundsLock.lock()
        activePlaybackSounds.removeValue(forKey: ObjectIdentifier(sound))
        activePlaybackSoundsLock.unlock()
    }

    private static func cleanupStaleStagedSoundFiles(
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

    private static func copyStagedSoundIfNeeded(
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

    private static func transcodeStagedSoundIfNeeded(
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

    private static func stagedCustomSoundSourceSignature(for sourceURL: URL) -> String {
        let normalizedPath = sourceURL.standardizedFileURL.path
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in normalizedPath.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private static func stagedSourceMetadataURL(for stagedURL: URL) -> URL {
        stagedURL.appendingPathExtension("source-metadata")
    }

    private static func currentSourceMetadata(for sourceURL: URL, fileManager: FileManager) -> CustomSoundSourceMetadata? {
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

    private static func loadStagedSourceMetadata(for stagedURL: URL) -> CustomSoundSourceMetadata? {
        let metadataURL = stagedSourceMetadataURL(for: stagedURL)
        guard let data = try? Data(contentsOf: metadataURL) else {
            return nil
        }
        return try? JSONDecoder().decode(CustomSoundSourceMetadata.self, from: data)
    }

    private static func saveStagedSourceMetadata(_ metadata: CustomSoundSourceMetadata, for stagedURL: URL) throws {
        let metadataURL = stagedSourceMetadataURL(for: stagedURL)
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }

    private static let customCommandRunner = NotificationCustomCommandRunner()

    static func runCustomCommand(title: String, subtitle: String, body: String, defaults: UserDefaults = .standard) {
        let command = defaults.string(forKey: customCommandKey) ?? defaultCustomCommand
        customCommandRunner.run(command: command, title: title, subtitle: subtitle, body: body)
    }
}
