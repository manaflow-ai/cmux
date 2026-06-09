import AppKit
import Foundation
import os
import UserNotifications
import Bonsplit

nonisolated private let terminalNotificationLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "notification"
)

// UNUserNotificationCenter.removeDeliveredNotifications(withIdentifiers:) and
// removePendingNotificationRequests(withIdentifiers:) perform synchronous XPC to
// usernoted under the hood. When usernoted is slow, this blocks the calling thread
// indefinitely. These helpers dispatch the calls off the main thread so they never
// freeze the UI.
extension UNUserNotificationCenter {
    private static let removalQueue = DispatchQueue(
        label: "com.cmuxterm.notification-removal",
        qos: .utility
    )

    func removeDeliveredNotificationsOffMain(withIdentifiers ids: [String]) {
        guard !ids.isEmpty else { return }
        Self.removalQueue.async {
            self.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func removePendingNotificationRequestsOffMain(withIdentifiers ids: [String]) {
        guard !ids.isEmpty else { return }
        Self.removalQueue.async {
            self.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}

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

    static func playSelectedSound(defaults: UserDefaults = .standard) {
        let value = defaults.string(forKey: key) ?? defaultValue
        playSound(value: value, defaults: defaults)
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
            let errorData = ProcessPipeReader.readDataToEndOfFileOrEmpty(from: errorPipe.fileHandleForReading)
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

    private static let customCommandQueue = DispatchQueue(
        label: "com.cmuxterm.notification-custom-command",
        qos: .utility
    )

    static func runCustomCommand(title: String, subtitle: String, body: String, defaults: UserDefaults = .standard) {
        let command = (defaults.string(forKey: customCommandKey) ?? defaultCustomCommand)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        customCommandQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            var env = ProcessInfo.processInfo.environment
            env["CMUX_NOTIFICATION_TITLE"] = title
            env["CMUX_NOTIFICATION_SUBTITLE"] = subtitle
            env["CMUX_NOTIFICATION_BODY"] = body
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                NSLog("Notification command failed to launch: \(error)")
            }
        }
    }
}

enum NotificationBadgeSettings {
    static let dockBadgeEnabledKey = "notificationDockBadgeEnabled"
    static let defaultDockBadgeEnabled = true

    static func isDockBadgeEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: dockBadgeEnabledKey) == nil {
            return defaultDockBadgeEnabled
        }
        return defaults.bool(forKey: dockBadgeEnabledKey)
    }
}

enum NotificationPaneRingSettings {
    static let enabledKey = "notificationPaneRingEnabled"
    static let defaultEnabled = true
}

enum NotificationPaneFlashSettings {
    static let enabledKey = "notificationPaneFlashEnabled"
    static let defaultEnabled = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil {
            return defaultEnabled
        }
        return defaults.bool(forKey: enabledKey)
    }
}

enum TaggedRunBadgeSettings {
    static let environmentKey = "CMUX_TAG"
    private static let maxTagLength = 10

    static func normalizedTag(from env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        normalizedTag(env[environmentKey])
    }

    static func normalizedTag(_ rawTag: String?) -> String? {
        guard var tag = rawTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else {
            return nil
        }
        if tag.count > maxTagLength {
            tag = String(tag.prefix(maxTagLength))
        }
        return tag
    }
}

enum AppFocusState {
    static var overrideIsFocused: Bool?

    static func isAppActive() -> Bool {
        if let overrideIsFocused {
            return overrideIsFocused
        }
        return NSApp.isActive
    }

    static func isAppFocused() -> Bool {
        if let overrideIsFocused {
            return overrideIsFocused
        }
        guard NSApp.isActive else { return false }
        guard let keyWindow = NSApp.keyWindow, keyWindow.isKeyWindow else { return false }
        // Only treat the app as "focused" for notification suppression when a main terminal window
        // is key. If Settings/About/debug panels are key, we still want notifications to show.
        if let raw = keyWindow.identifier?.rawValue {
            return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
        }
        return false
    }
}

enum NotificationAuthorizationState: Equatable {
    case unknown
    case notDetermined
    case authorized
    case denied
    case provisional
    case ephemeral

    var statusLabel: String {
        switch self {
        case .unknown, .notDetermined:
            return "Not Requested"
        case .authorized:
            return "Allowed"
        case .denied:
            return "Denied"
        case .provisional:
            return "Deliver Quietly"
        case .ephemeral:
            return "Temporary"
        }
    }

    var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .unknown, .notDetermined, .denied:
            return false
        }
    }
}

enum TerminalNotificationClickAction: Codable, Hashable, Sendable {
    case revealInFinder(path: String)

    private static let kindUserInfoKey = "cmuxClickAction"
    private static let revealInFinderPathUserInfoKey = "cmuxRevealInFinderPath"
    private static let revealInFinderKind = "revealInFinder"

    var userInfo: [String: String] {
        switch self {
        case .revealInFinder(let path):
            return [
                Self.kindUserInfoKey: Self.revealInFinderKind,
                Self.revealInFinderPathUserInfoKey: path,
            ]
        }
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let kind = userInfo[Self.kindUserInfoKey] as? String else { return nil }
        switch kind {
        case Self.revealInFinderKind:
            guard let path = userInfo[Self.revealInFinderPathUserInfoKey] as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self = .revealInFinder(path: path)
        default:
            return nil
        }
    }
}

struct TerminalNotification: Identifiable, Hashable {
    let id: UUID
    let tabId: UUID
    let surfaceId: UUID?
    let panelId: UUID?
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Date
    var isRead: Bool
    var paneFlash: Bool = true
    var clickAction: TerminalNotificationClickAction?

    init(
        id: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID? = nil,
        title: String,
        subtitle: String,
        body: String,
        createdAt: Date,
        isRead: Bool,
        paneFlash: Bool = true,
        clickAction: TerminalNotificationClickAction? = nil
    ) {
        self.id = id
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.panelId = panelId
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.paneFlash = paneFlash
        self.clickAction = clickAction
    }

    func matches(tabId targetTabId: UUID, surfaceId targetSurfaceId: UUID?) -> Bool {
        guard tabId == targetTabId else { return false }
        guard let targetSurfaceId else {
            return surfaceId == nil && panelId == nil
        }
        return surfaceId == targetSurfaceId || panelId == targetSurfaceId
    }
}

@MainActor
final class TerminalNotificationStore: ObservableObject {
    private struct TabSurfaceKey: Hashable {
        let tabId: UUID
        let surfaceId: UUID?
    }

    private struct NotificationIndexes {
        var unreadCount = 0
        var unreadCountByTabId: [UUID: Int] = [:]
        var unreadByTabSurface = Set<TabSurfaceKey>()
        var latestUnreadByTabId: [UUID: TerminalNotification] = [:]
        var latestByTabId: [UUID: TerminalNotification] = [:]
    }

    static let shared = TerminalNotificationStore()

    static let categoryIdentifier = "com.cmuxterm.app.userNotification"
    static let actionShowIdentifier = "com.cmuxterm.app.userNotification.show"
    private enum AuthorizationRequestOrigin: String {
        case notificationDelivery = "notification_delivery"
        case settingsButton = "settings_button"
        case settingsTest = "settings_test"
    }

    @Published private(set) var notifications: [TerminalNotification] = [] {
        didSet {
            indexes = Self.buildIndexes(for: notifications)
            refreshUnreadPresentation()
            if !suppressNotificationDiffPublishing { CmuxEventBus.shared.publishNotificationChanges(oldValue: oldValue, newValue: notifications) }
        }
    }
    @Published private(set) var notificationMenuSnapshot = NotificationMenuSnapshotBuilder.make(notifications: [])
    // Workspace-level unread drives sidebar workspace badges; pane-level manual
    // unread remains owned by Workspace.manualUnreadPanelIds.
    @Published private(set) var manualUnreadWorkspaceIds: Set<UUID> = [] {
        didSet { refreshUnreadPresentation() }
    }
    @Published private(set) var panelDerivedUnreadWorkspaceIds: Set<UUID> = [] {
        didSet { refreshUnreadPresentation() }
    }
    @Published private(set) var restoredUnreadWorkspaceIds: Set<UUID> = [] {
        didSet { refreshUnreadPresentation() }
    }
    @Published private(set) var focusedReadIndicatorByTabId: [UUID: UUID] = [:]
    @Published private(set) var authorizationState: NotificationAuthorizationState = .unknown
    private var suppressNotificationDiffPublishing = false

    private let center = UNUserNotificationCenter.current()
    private var hasRequestedAutomaticAuthorization = false
    private var hasDeferredAuthorizationRequest = false
    private var hasPromptedForSettings = false
    private var userDefaultsObserver: NSObjectProtocol?
    private let settingsPromptWindowRetryDelay: TimeInterval = 0.5
    private let settingsPromptWindowRetryLimit = 20
    private var notificationSettingsWindowProvider: () -> NSWindow? = {
        NSApp.keyWindow ?? NSApp.mainWindow
    }
    private var notificationSettingsAlertFactory: () -> NSAlert = {
        NSAlert()
    }
    private var notificationSettingsScheduler: (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void = {
        delay,
        block in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            block()
        }
    }
    private var notificationSettingsURLOpener: (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }
    private var notificationDeliveryHandler: (TerminalNotificationStore, TerminalNotification, TerminalNotificationPolicyEffects) -> Void = {
        store,
        notification,
        effects in
        store.scheduleUserNotification(notification, effects: effects)
    }
    private var suppressedNotificationFeedbackHandler: (TerminalNotificationStore, TerminalNotification, TerminalNotificationPolicyEffects) -> Void = {
        store,
        notification,
        effects in
        store.playSuppressedNotificationFeedback(for: notification, effects: effects)
    }
    private struct NotificationHookFailureThrottleKey: Hashable {
        let hookId: String
        let sourcePath: String?
    }

    private static let notificationHookFailureThrottle: TimeInterval = 300
    private var lastNotificationDateByCooldownKey: [String: Date] = [:]
    private var lastNotificationHookFailureDateByKey: [NotificationHookFailureThrottleKey: Date] = [:]
    private var indexes = NotificationIndexes()

    private init() {
        indexes = Self.buildIndexes(for: notifications)
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDockBadge()
        }
        refreshDockBadge()
        refreshAuthorizationStatus()
    }

    deinit {
        if let userDefaultsObserver {
            NotificationCenter.default.removeObserver(userDefaultsObserver)
        }
    }

    static func dockBadgeLabel(unreadCount: Int, isEnabled: Bool, runTag: String? = nil) -> String? {
        let unreadLabel: String? = {
            guard isEnabled, unreadCount > 0 else { return nil }
            if unreadCount > 99 {
                return "99+"
            }
            return String(unreadCount)
        }()

        if let tag = TaggedRunBadgeSettings.normalizedTag(runTag) {
            if let unreadLabel {
                return "\(tag):\(unreadLabel)"
            }
            return tag
        }

        return unreadLabel
    }

    var unreadCount: Int {
        indexes.unreadCount + workspaceUnreadIndicatorCount
    }

    var workspaceUnreadIndicatorIds: Set<UUID> {
        manualUnreadWorkspaceIds
            .union(panelDerivedUnreadWorkspaceIds)
            .union(restoredUnreadWorkspaceIds)
    }

    private var workspaceUnreadIndicatorCount: Int {
        workspaceUnreadIndicatorIds.count
    }

    private func refreshUnreadPresentation() {
        let nextMenuSnapshot = NotificationMenuSnapshotBuilder.make(
            notifications: notifications,
            workspaceUnreadIndicatorCount: workspaceUnreadIndicatorCount
        )
        if notificationMenuSnapshot != nextMenuSnapshot {
            notificationMenuSnapshot = nextMenuSnapshot
        }
        refreshDockBadge()
    }

    private func logAuthorization(_ message: String) {
#if DEBUG
        cmuxDebugLog("notification.auth \(message)")
#endif
        NSLog("notification.auth %@", message)
    }

    private static func authorizationStatusLabel(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "unknown(\(status.rawValue))"
        }
    }

    func refreshAuthorizationStatus() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizationState = Self.authorizationState(from: settings.authorizationStatus)
                self.logAuthorization(
                    "refresh status=\(Self.authorizationStatusLabel(settings.authorizationStatus)) mapped=\(self.authorizationState.statusLabel)"
                )
            }
        }
    }

    func requestAuthorizationFromSettings() {
        logAuthorization("settings request tapped state=\(authorizationState.statusLabel)")
        ensureAuthorization(origin: .settingsButton) { _ in }
    }

    func openNotificationSettings() {
        guard let url = Self.notificationSettingsURL(bundleIdentifier: Bundle.main.bundleIdentifier) else { return }
        logAuthorization("open settings url=\(url.absoluteString)")
        notificationSettingsURLOpener(url)
    }

    static func notificationSettingsURL(bundleIdentifier: String?) -> URL? {
        if let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty,
           let encodedBundleIdentifier = bundleIdentifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(
                string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(encodedBundleIdentifier)"
            )
        }
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }

    func sendSettingsTestNotification() {
        logAuthorization("settings test tapped state=\(authorizationState.statusLabel)")
        ensureAuthorization(origin: .settingsTest) { [weak self] authorized in
            guard let self, authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = "cmux test notification"
            content.body = "Desktop notifications are enabled."
            content.sound = NotificationSoundSettings.sound()
            content.categoryIdentifier = Self.categoryIdentifier

            let request = UNNotificationRequest(
                identifier: "cmux.settings.test.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            self.center.add(request) { error in
                if let error {
                    NSLog("Failed to schedule test notification: \(error)")
                    self.logAuthorization("settings test schedule failed error=\(error.localizedDescription)")
                } else {
                    self.logAuthorization("settings test schedule succeeded")
                    NotificationSoundSettings.runCustomCommand(
                        title: content.title,
                        subtitle: content.subtitle,
                        body: content.body
                    )
                }
            }
        }
    }

    func handleApplicationDidBecomeActive() {
        logAuthorization("app became active deferred=\(hasDeferredAuthorizationRequest)")
        if hasDeferredAuthorizationRequest {
            hasDeferredAuthorizationRequest = false
            ensureAuthorization(origin: .settingsButton) { _ in }
            return
        }
        refreshAuthorizationStatus()
    }

    @discardableResult
    private func setWorkspaceManualUnread(_ isUnread: Bool, forTabId tabId: UUID) -> Bool {
        var nextIds = manualUnreadWorkspaceIds
        let didChange: Bool
        if isUnread {
            didChange = nextIds.insert(tabId).inserted
        } else {
            didChange = nextIds.remove(tabId) != nil
        }
        guard didChange else { return false }
        manualUnreadWorkspaceIds = nextIds
        return true
    }

    private func clearWorkspaceManualUnread() {
        guard !manualUnreadWorkspaceIds.isEmpty else { return }
        manualUnreadWorkspaceIds = []
    }

    @discardableResult
    private func setPanelDerivedWorkspaceUnread(_ isUnread: Bool, forTabId tabId: UUID) -> Bool {
        var nextIds = panelDerivedUnreadWorkspaceIds
        let didChange: Bool
        if isUnread {
            didChange = nextIds.insert(tabId).inserted
        } else {
            didChange = nextIds.remove(tabId) != nil
        }
        guard didChange else { return false }
        panelDerivedUnreadWorkspaceIds = nextIds
        return true
    }

    private func clearPanelDerivedWorkspaceUnread() {
        guard !panelDerivedUnreadWorkspaceIds.isEmpty else { return }
        panelDerivedUnreadWorkspaceIds = []
    }

    private func clearWorkspacePanelUnread(forTabId tabId: UUID) {
        guard let appDelegate = AppDelegate.shared else { return }
        let workspace = appDelegate.workspaceFor(tabId: tabId) ??
            appDelegate.tabManager?.tabs.first(where: { $0.id == tabId })
        workspace?.clearAllPanelUnreadIndicatorsForWorkspaceRead()
    }

    private func clearAllWorkspacePanelUnread(forTabIds tabIds: Set<UUID>) {
        for tabId in tabIds {
            clearWorkspacePanelUnread(forTabId: tabId)
        }
    }

    @discardableResult
    private func setWorkspaceRestoredUnread(_ isUnread: Bool, forTabId tabId: UUID) -> Bool {
        var nextIds = restoredUnreadWorkspaceIds
        let didChange: Bool
        if isUnread {
            didChange = nextIds.insert(tabId).inserted
        } else {
            didChange = nextIds.remove(tabId) != nil
        }
        guard didChange else { return false }
        restoredUnreadWorkspaceIds = nextIds
        return true
    }

    private func clearWorkspaceRestoredUnread() {
        guard !restoredUnreadWorkspaceIds.isEmpty else { return }
        restoredUnreadWorkspaceIds = []
    }

    func hasManualUnread(forTabId tabId: UUID) -> Bool {
        manualUnreadWorkspaceIds.contains(tabId)
    }

    func hasPanelDerivedUnread(forTabId tabId: UUID) -> Bool {
        panelDerivedUnreadWorkspaceIds.contains(tabId)
    }

    func hasRestoredUnreadIndicator(forTabId tabId: UUID) -> Bool {
        restoredUnreadWorkspaceIds.contains(tabId)
    }

    @discardableResult
    func setPanelDerivedUnread(_ isUnread: Bool, forTabId tabId: UUID) -> Bool {
        setPanelDerivedWorkspaceUnread(isUnread, forTabId: tabId)
    }

    @discardableResult
    func restoreUnreadIndicator(forTabId tabId: UUID) -> Bool {
        setWorkspaceRestoredUnread(true, forTabId: tabId)
    }

    @discardableResult
    func clearRestoredUnreadIndicator(forTabId tabId: UUID) -> Bool {
        setWorkspaceRestoredUnread(false, forTabId: tabId)
    }

    @discardableResult
    func clearManualUnread(forTabId tabId: UUID) -> Bool {
        setWorkspaceManualUnread(false, forTabId: tabId)
    }

    // Per-workspace badges treat workspace indicators as unread activity;
    // summing these counts can exceed indexes.unreadCount.
    func unreadCount(forTabId tabId: UUID) -> Int {
        let hasWorkspaceUnreadIndicator = manualUnreadWorkspaceIds.contains(tabId) ||
            panelDerivedUnreadWorkspaceIds.contains(tabId) ||
            restoredUnreadWorkspaceIds.contains(tabId)
        return (indexes.unreadCountByTabId[tabId] ?? 0) + (hasWorkspaceUnreadIndicator ? 1 : 0)
    }

    func workspaceIsUnread(forTabId tabId: UUID) -> Bool {
        unreadCount(forTabId: tabId) > 0
    }

    func canMarkWorkspaceRead(forTabIds tabIds: [UUID]) -> Bool {
        tabIds.contains { workspaceIsUnread(forTabId: $0) }
    }

    func canMarkWorkspaceUnread(forTabIds tabIds: [UUID]) -> Bool {
        tabIds.contains { !workspaceIsUnread(forTabId: $0) }
    }

    func hasUnreadNotification(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        indexes.unreadByTabSurface.contains(TabSurfaceKey(tabId: tabId, surfaceId: surfaceId))
    }

    func hasUnreadNotificationRequiringPaneFlash(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        notifications.contains { notification in
            notification.matches(tabId: tabId, surfaceId: surfaceId) &&
                !notification.isRead &&
                notification.paneFlash
        }
    }

    func hasVisibleNotificationIndicator(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId) ||
            (focusedReadIndicatorByTabId[tabId].map { $0 == surfaceId } ?? false)
    }

    func latestNotification(forTabId tabId: UUID) -> TerminalNotification? {
        indexes.latestByTabId[tabId]
    }

    func notifications(forTabId tabId: UUID, surfaceId: UUID?) -> [TerminalNotification] {
        notifications.filter { $0.matches(tabId: tabId, surfaceId: surfaceId) }
    }

    func clearLatestNotification(forTabId tabId: UUID) {
        guard let latestNotification = indexes.latestByTabId[tabId] else { return }
        remove(id: latestNotification.id)
    }

    func focusedReadIndicatorSurfaceId(forTabId tabId: UUID) -> UUID? {
        focusedReadIndicatorByTabId[tabId]
    }

    func addNotification(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String,
        cooldownKey: String? = nil,
        cooldownInterval: TimeInterval? = nil,
        clickAction: TerminalNotificationClickAction? = nil
    ) {
#if DEBUG
        cmuxDebugLog(
            "notification.store.add workspace=\(tabId.uuidString.prefix(8)) surface=\(surfaceId?.uuidString.prefix(8) ?? "nil") titleLen=\(title.count) subtitleLen=\(subtitle.count) bodyLen=\(body.count) cooldown=\(cooldownKey == nil ? 0 : 1)"
        )
#endif
        let now = Date()
        let resolvedCooldownInterval: TimeInterval?
        if let cooldownInterval, cooldownInterval.isFinite, cooldownInterval > 0 {
            resolvedCooldownInterval = cooldownInterval
        } else {
            resolvedCooldownInterval = nil
        }
        if let cooldownKey,
           let resolvedCooldownInterval,
           let lastNotificationDate = lastNotificationDateByCooldownKey[cooldownKey],
           now.timeIntervalSince(lastNotificationDate) < resolvedCooldownInterval {
#if DEBUG
            cmuxDebugLog(
                "notification.store.add.skip workspace=\(tabId.uuidString.prefix(8)) surface=\(surfaceId?.uuidString.prefix(8) ?? "nil") reason=cooldown"
            )
#endif
            return
        }
        let cooldownReservation = makeCooldownReservation(
            key: cooldownKey,
            interval: resolvedCooldownInterval
        )
        if let cooldownReservation {
            lastNotificationDateByCooldownKey[cooldownReservation.key] = now
        }

        let policyContext = makeNotificationPolicyContext(
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body
        )
        guard !policyContext.hooks.isEmpty else {
            applyNotification(
                request: policyContext.request,
                effects: TerminalNotificationPolicyEffects(),
                now: now,
                cooldownReservation: cooldownReservation,
                clickAction: clickAction
            )
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let authorizedHooks = await NotificationPolicyHookAuthorizer.authorize(
                policyContext.hooks,
                globalConfigPath: policyContext.globalConfigPath
            )
            guard !authorizedHooks.isEmpty else {
                self.applyNotification(
                    request: policyContext.request,
                    effects: TerminalNotificationPolicyEffects(),
                    now: Date(),
                    cooldownReservation: cooldownReservation,
                    clickAction: clickAction
                )
                return
            }

            let result = await TerminalNotificationPolicyEngine.evaluate(
                request: policyContext.request,
                hooks: authorizedHooks
            )
            switch result {
            case .success(let envelope):
                self.applyNotification(
                    request: policyContext.request,
                    envelope: envelope,
                    now: Date(),
                    cooldownReservation: cooldownReservation,
                    clickAction: clickAction
                )
            case .failure(let failure):
                self.applyNotification(
                    request: policyContext.request,
                    effects: TerminalNotificationPolicyEffects(),
                    now: Date(),
                    cooldownReservation: cooldownReservation,
                    clickAction: clickAction
                )
                self.reportNotificationHookFailure(failure)
            }
        }
    }

    private struct NotificationCooldownReservation: Sendable {
        let key: String
        let previousDate: Date?
    }

    private struct NotificationPolicyContext: Sendable {
        let request: TerminalNotificationPolicyRequest
        let hooks: [CmuxResolvedNotificationHook]
        let globalConfigPath: String?
    }

    private func makeCooldownReservation(
        key: String?,
        interval: TimeInterval?
    ) -> NotificationCooldownReservation? {
        guard let key, interval != nil else { return nil }
        return NotificationCooldownReservation(
            key: key,
            previousDate: lastNotificationDateByCooldownKey[key]
        )
    }

    private func commitCooldownReservation(
        _ reservation: NotificationCooldownReservation?,
        at date: Date
    ) {
        guard let reservation else { return }
        lastNotificationDateByCooldownKey[reservation.key] = date
    }

    private func restoreCooldownReservation(_ reservation: NotificationCooldownReservation?) {
        guard let reservation else { return }
        if let previousDate = reservation.previousDate {
            lastNotificationDateByCooldownKey[reservation.key] = previousDate
        } else {
            lastNotificationDateByCooldownKey.removeValue(forKey: reservation.key)
        }
    }

    private func makeNotificationPolicyContext(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String
    ) -> NotificationPolicyContext {
        let appDelegate = AppDelegate.shared
        let context = appDelegate?.contextContainingTabId(tabId)
        let tabManager = context?.tabManager ?? appDelegate?.tabManagerFor(tabId: tabId) ?? appDelegate?.tabManager
        let cmuxConfigStore = context?.cmuxConfigStore
        let workspace = tabManager?.tabs.first(where: { $0.id == tabId })
        let focusedSurfaceId = tabManager?.focusedSurfaceId(for: tabId)
        let isActiveTab = tabManager?.selectedTabId == tabId
        let isFocusedSurface = surfaceId == nil || focusedSurfaceId == surfaceId
        let isFocusedPanel = isActiveTab && isFocusedSurface
        let isAppFocused = AppFocusState.isAppFocused()
        let cwd = workspace?.surfaceTabBarDirectory
            ?? workspace?.currentDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let panelId: UUID? = surfaceId.flatMap { surfaceId in
            if workspace?.panels[surfaceId] != nil {
                return surfaceId
            }
            return workspace?.panelIdFromSurfaceId(TabID(uuid: surfaceId))
        }

        return NotificationPolicyContext(
            request: TerminalNotificationPolicyRequest(
                tabId: tabId,
                surfaceId: surfaceId,
                panelId: panelId,
                title: title,
                subtitle: subtitle,
                body: body,
                cwd: cwd,
                isAppFocused: isAppFocused,
                isFocusedPanel: isFocusedPanel
            ),
            hooks: cmuxConfigStore?.notificationHooks(startingFrom: cwd) ?? [],
            globalConfigPath: cmuxConfigStore?.globalConfigPath
        )
    }

    private func applyNotification(
        request: TerminalNotificationPolicyRequest,
        envelope: TerminalNotificationPolicyEnvelope,
        now: Date,
        cooldownReservation: NotificationCooldownReservation?,
        clickAction: TerminalNotificationClickAction?
    ) {
        let payload = envelope.notification
        applyNotification(
            request: TerminalNotificationPolicyRequest(
                tabId: request.tabId,
                surfaceId: request.surfaceId,
                panelId: request.panelId,
                title: payload.title,
                subtitle: payload.subtitle,
                body: payload.body,
                cwd: request.cwd,
                isAppFocused: request.isAppFocused,
                isFocusedPanel: request.isFocusedPanel
            ),
            effects: envelope.effects,
            now: now,
            cooldownReservation: cooldownReservation,
            clickAction: clickAction
        )
    }

    private func applyNotification(
        request: TerminalNotificationPolicyRequest,
        effects: TerminalNotificationPolicyEffects,
        now: Date,
        cooldownReservation: NotificationCooldownReservation?,
        clickAction: TerminalNotificationClickAction?
    ) {
        let shouldSuppressExternalDelivery = shouldSuppressExternalDelivery(
            tabId: request.tabId,
            surfaceId: request.surfaceId
        )
        let notification = TerminalNotification(
            id: UUID(),
            tabId: request.tabId,
            surfaceId: request.surfaceId,
            panelId: request.panelId,
            title: request.title,
            subtitle: request.subtitle,
            body: request.body,
            createdAt: now,
            isRead: !effects.markUnread,
            paneFlash: effects.paneFlash,
            clickAction: clickAction
        )

        if effects.record {
            recordNotification(
                notification,
                shouldSuppressExternalDelivery: shouldSuppressExternalDelivery,
                effects: effects,
                now: now,
                cooldownReservation: cooldownReservation
            )
            return
        }

#if DEBUG
        cmuxDebugLog(
            "notification.store.effectsOnly workspace=\(notification.tabId.uuidString.prefix(8)) surface=\(notification.surfaceId?.uuidString.prefix(8) ?? "nil") desktop=\(effects.desktop ? 1 : 0) sound=\(effects.sound ? 1 : 0) command=\(effects.command ? 1 : 0) suppressExternal=\(shouldSuppressExternalDelivery ? 1 : 0)"
        )
#endif
        if effects.reorderWorkspace, WorkspaceAutoReorderSettings.isEnabled() {
            AppDelegate.shared?.tabManagerFor(tabId: notification.tabId)?
                .moveTabToTopForNotification(notification.tabId)
        }
        if hasAnyNotificationEffect(effects) {
            commitCooldownReservation(cooldownReservation, at: now)
        } else {
            restoreCooldownReservation(cooldownReservation)
        }
        deliverNotificationSideEffects(
            notification,
            shouldSuppressExternalDelivery: shouldSuppressExternalDelivery,
            effects: effects
        )
    }

    private func recordNotification(
        _ notification: TerminalNotification,
        shouldSuppressExternalDelivery: Bool,
        effects: TerminalNotificationPolicyEffects,
        now: Date,
        cooldownReservation: NotificationCooldownReservation?
    ) {
        var updated = notifications
        var idsToClear: [String] = []
        updated.removeAll { existing in
            guard existing.tabId == notification.tabId, existing.surfaceId == notification.surfaceId else { return false }
            idsToClear.append(existing.id.uuidString)
            return true
        }

        if let existingIndicatorSurfaceId = focusedReadIndicatorByTabId[notification.tabId],
           existingIndicatorSurfaceId != notification.surfaceId {
            focusedReadIndicatorByTabId.removeValue(forKey: notification.tabId)
        }

        if shouldSuppressExternalDelivery, effects.markUnread {
            setFocusedReadIndicator(forTabId: notification.tabId, surfaceId: notification.surfaceId)
        }

        if effects.reorderWorkspace, WorkspaceAutoReorderSettings.isEnabled() {
            AppDelegate.shared?.tabManagerFor(tabId: notification.tabId)?
                .moveTabToTopForNotification(notification.tabId)
        }

        updated.insert(notification, at: 0)
        setWorkspaceManualUnread(false, forTabId: notification.tabId)
        notifications = updated
        commitCooldownReservation(cooldownReservation, at: now)
#if DEBUG
        cmuxDebugLog(
            "notification.store.record workspace=\(notification.tabId.uuidString.prefix(8)) surface=\(notification.surfaceId?.uuidString.prefix(8) ?? "nil") removed=\(idsToClear.count) unread=\(!notification.isRead ? 1 : 0) paneFlash=\(notification.paneFlash ? 1 : 0) suppressExternal=\(shouldSuppressExternalDelivery ? 1 : 0) total=\(notifications.count)"
        )
#endif
        if !idsToClear.isEmpty {
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
        deliverNotificationSideEffects(
            notification,
            shouldSuppressExternalDelivery: shouldSuppressExternalDelivery,
            effects: effects
        )
    }

    private func shouldSuppressExternalDelivery(tabId: UUID, surfaceId: UUID?) -> Bool {
        let appDelegate = AppDelegate.shared
        let context = appDelegate?.contextContainingTabId(tabId)
        let tabManager = context?.tabManager ?? appDelegate?.tabManagerFor(tabId: tabId) ?? appDelegate?.tabManager
        let focusedSurfaceId = tabManager?.focusedSurfaceId(for: tabId)
        let isActiveTab = tabManager?.selectedTabId == tabId
        let isFocusedSurface = surfaceId == nil || focusedSurfaceId == surfaceId
        return AppFocusState.isAppFocused() && isActiveTab && isFocusedSurface
    }

    private func deliverNotificationSideEffects(
        _ notification: TerminalNotification,
        shouldSuppressExternalDelivery: Bool,
        effects: TerminalNotificationPolicyEffects
    ) {
        guard effects.desktop || effects.sound || effects.command else {
#if DEBUG
            cmuxDebugLog(
                "notification.store.sideEffects.skip workspace=\(notification.tabId.uuidString.prefix(8)) surface=\(notification.surfaceId?.uuidString.prefix(8) ?? "nil") reason=noEffects"
            )
#endif
            return
        }
#if DEBUG
        cmuxDebugLog(
            "notification.store.sideEffects workspace=\(notification.tabId.uuidString.prefix(8)) surface=\(notification.surfaceId?.uuidString.prefix(8) ?? "nil") desktop=\(effects.desktop ? 1 : 0) sound=\(effects.sound ? 1 : 0) command=\(effects.command ? 1 : 0) suppressExternal=\(shouldSuppressExternalDelivery ? 1 : 0)"
        )
#endif
        if shouldSuppressExternalDelivery {
            suppressedNotificationFeedbackHandler(self, notification, effects)
        } else {
            notificationDeliveryHandler(self, notification, effects)
            // Mirror to the user's iPhone (opt-in, off by default). Only on the
            // desktop-delivery path so it matches what the Mac actually shows;
            // suppressed/focused notifications are not forwarded.
            if effects.desktop {
                PhonePushClient.shared.forward(notification)
            }
        }
    }

    private func hasAnyNotificationEffect(_ effects: TerminalNotificationPolicyEffects) -> Bool {
        effects.record || effects.desktop || effects.sound || effects.command || effects.reorderWorkspace || effects.markUnread
    }

    func reportNotificationHookFailure(_ failure: TerminalNotificationPolicyFailure) {
        let key = NotificationHookFailureThrottleKey(
            hookId: failure.hookId,
            sourcePath: failure.sourcePath
        )
        let now = Date()
        if let lastDate = lastNotificationHookFailureDateByKey[key],
           now.timeIntervalSince(lastDate) < Self.notificationHookFailureThrottle {
            return
        }
        lastNotificationHookFailureDateByKey[key] = now
        terminalNotificationLogger.error(
            "Notification hook failed hookId=\(failure.hookId, privacy: .public) sourcePath=\(failure.sourcePath ?? "<unknown>", privacy: .private) message=\(failure.message, privacy: .private)"
        )

        ensureAuthorization(origin: .notificationDelivery) { [weak self] authorized in
            guard let self, authorized else { return }
            let title = String(
                localized: "notificationHook.failure.title",
                defaultValue: "Notification Hook Failed"
            )
            let format = String(
                localized: "notificationHook.failure.body",
                defaultValue: "cmux used default notification behavior because '%@' failed."
            )
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = String(format: format, failure.hookId)
            content.sound = NotificationSoundSettings.sound()
            content.categoryIdentifier = Self.categoryIdentifier
            let request = UNNotificationRequest(
                identifier: "cmux.notification-hook.failure.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            self.center.add(request) { error in
                if let error {
                    terminalNotificationLogger.error(
                        "Failed to schedule notification hook failure alert error=\(error.localizedDescription, privacy: .private)"
                    )
                }
            }
        }
    }

    func markRead(id: UUID) {
        var updated = notifications
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        guard !updated[index].isRead else { return }
        updated[index].isRead = true
        notifications = updated
        center.removeDeliveredNotificationsOffMain(withIdentifiers: [id.uuidString])
    }

    func markUnread(id: UUID) {
        var updated = notifications
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        guard updated[index].isRead else { return }
        let tabId = updated[index].tabId
        updated[index].isRead = false
        notifications = updated
        // The notification itself now provides the workspace unread indicator. Clear any
        // existing manual or restored workspace unread state for the same tab so we don't
        // double-count it. (Mirrors what markLatestNotificationAsOldestUnread does for the
        // manual flag — restored hints are a one-time signal from a previous session and
        // should also defer to the concrete unread notification.)
        setWorkspaceManualUnread(false, forTabId: tabId)
        setWorkspaceRestoredUnread(false, forTabId: tabId)
    }

    func markRead(forTabId tabId: UUID) {
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if updated[index].tabId == tabId && !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
        }
        clearFocusedReadIndicator(forTabId: tabId)
        setWorkspaceManualUnread(false, forTabId: tabId)
        clearWorkspacePanelUnread(forTabId: tabId)
        setPanelDerivedWorkspaceUnread(false, forTabId: tabId)
        setWorkspaceRestoredUnread(false, forTabId: tabId)
        if !idsToClear.isEmpty {
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        }
    }

    func markRead(forTabId tabId: UUID, surfaceId: UUID?) {
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if updated[index].matches(tabId: tabId, surfaceId: surfaceId),
               !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
        }
        clearFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)
        if surfaceId == nil {
            clearWorkspacePanelUnread(forTabId: tabId)
            setPanelDerivedWorkspaceUnread(false, forTabId: tabId)
            setWorkspaceRestoredUnread(false, forTabId: tabId)
        }
        if !idsToClear.isEmpty {
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
    }

    func markUnread(forTabId tabId: UUID) {
        setWorkspaceManualUnread(true, forTabId: tabId)
        setWorkspaceRestoredUnread(false, forTabId: tabId)
    }

    @discardableResult
    func markLatestNotificationAsOldestUnread(forTabId tabId: UUID, surfaceId: UUID?) -> UUID? {
        var updated = notifications
        guard let index = latestNotificationIndex(forTabId: tabId, surfaceId: surfaceId, in: updated) else {
            if surfaceId == nil, !workspaceIsUnread(forTabId: tabId) {
                setWorkspaceManualUnread(true, forTabId: tabId)
            }
            return nil
        }

        var notification = updated.remove(at: index)
        notification.isRead = false
        let insertionIndex = updated.lastIndex(where: { !$0.isRead }).map { $0 + 1 } ?? updated.endIndex
        updated.insert(notification, at: insertionIndex)
        setWorkspaceManualUnread(false, forTabId: tabId)
        notifications = updated
        return notification.id
    }

    private func latestNotificationIndex(forTabId tabId: UUID, surfaceId: UUID?, in notifications: [TerminalNotification]) -> Int? {
        if let exactIndex = notifications.firstIndex(where: { $0.matches(tabId: tabId, surfaceId: surfaceId) }) {
            return exactIndex
        }
        if surfaceId != nil,
           let workspaceIndex = notifications.firstIndex(where: { $0.tabId == tabId && $0.surfaceId == nil }) {
            return workspaceIndex
        }
        return notifications.firstIndex(where: { $0.tabId == tabId })
    }

    func setFocusedReadIndicator(forTabId tabId: UUID, surfaceId: UUID?) {
        guard let surfaceId else { return }
        guard focusedReadIndicatorByTabId[tabId] != surfaceId else { return }
        focusedReadIndicatorByTabId[tabId] = surfaceId
    }

    func clearFocusedReadIndicator(forTabId tabId: UUID, surfaceId: UUID? = nil) {
        guard let existingSurfaceId = focusedReadIndicatorByTabId[tabId] else { return }
        guard surfaceId == nil || existingSurfaceId == surfaceId else { return }
        focusedReadIndicatorByTabId.removeValue(forKey: tabId)
    }

    func clearFocusedReadIndicatorIfSurfaceChanged(forTabId tabId: UUID, surfaceId: UUID?) {
        guard let existingSurfaceId = focusedReadIndicatorByTabId[tabId] else { return }
        guard existingSurfaceId != surfaceId else { return }
        focusedReadIndicatorByTabId.removeValue(forKey: tabId)
    }

    func markAllRead() {
        var updated = notifications
        var idsToClear: [String] = []
        var tabIdsToClearPanelUnread = panelDerivedUnreadWorkspaceIds
        for index in updated.indices {
            if !updated[index].isRead {
                tabIdsToClearPanelUnread.insert(updated[index].tabId)
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
        }
        clearWorkspaceManualUnread()
        clearAllWorkspacePanelUnread(forTabIds: tabIdsToClearPanelUnread)
        clearPanelDerivedWorkspaceUnread()
        clearWorkspaceRestoredUnread()
        if !idsToClear.isEmpty {
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
    }

    func remove(id: UUID) {
        var updated = notifications
        let removed = updated.first(where: { $0.id == id })
        let originalCount = updated.count
        updated.removeAll { $0.id == id }
        guard updated.count != originalCount else { return }
        notifications = updated
        if let removed {
            clearFocusedReadIndicator(forTabId: removed.tabId, surfaceId: removed.surfaceId)
        }
        center.removeDeliveredNotificationsOffMain(withIdentifiers: [id.uuidString])
    }

    func restoreSessionNotifications(_ restoredNotifications: [TerminalNotification], forTabId tabId: UUID) {
        TerminalMutationBus.shared.discardPendingNotifications(forTabId: tabId)

        let removedIds = notifications
            .filter { $0.tabId == tabId }
            .map { $0.id.uuidString }
        var usedNotificationIds = Set(notifications.filter { $0.tabId != tabId }.map(\.id))
        let restoredForTab = restoredNotifications
            .filter { $0.tabId == tabId }
            .sorted(by: Self.notificationSortPrecedes)
            .map { Self.notificationWithUniqueId($0, usedIds: &usedNotificationIds) }
        let keptNotifications = notifications.filter { $0.tabId != tabId }
        let nextNotifications = (restoredForTab + keptNotifications).sorted(by: Self.notificationSortPrecedes)

        let didChangeNotifications = nextNotifications != notifications
        if didChangeNotifications {
            notifications = nextNotifications
        }
        clearFocusedReadIndicator(forTabId: tabId)

        if didChangeNotifications, !removedIds.isEmpty {
            center.removeDeliveredNotificationsOffMain(withIdentifiers: removedIds)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: removedIds)
        }
    }

    private static func notificationWithUniqueId(
        _ notification: TerminalNotification,
        usedIds: inout Set<UUID>
    ) -> TerminalNotification {
        if usedIds.insert(notification.id).inserted {
            return notification
        }

        var replacementId = UUID()
        while !usedIds.insert(replacementId).inserted {
            replacementId = UUID()
        }

        return TerminalNotification(
            id: replacementId,
            tabId: notification.tabId,
            surfaceId: notification.surfaceId,
            panelId: notification.panelId,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            createdAt: notification.createdAt,
            isRead: notification.isRead,
            paneFlash: notification.paneFlash,
            clickAction: notification.clickAction
        )
    }

    private func replaceNotificationsForClear(_ next: [TerminalNotification]) { suppressNotificationDiffPublishing = true; notifications = next; suppressNotificationDiffPublishing = false }

    func clearAll(discardQueuedNotifications: Bool = true) {
        if discardQueuedNotifications { TerminalMutationBus.shared.discardPendingNotifications() }
        guard !notifications.isEmpty ||
            !focusedReadIndicatorByTabId.isEmpty ||
            !manualUnreadWorkspaceIds.isEmpty ||
            !panelDerivedUnreadWorkspaceIds.isEmpty ||
            !restoredUnreadWorkspaceIds.isEmpty else { return }
        let tabIdsToClearPanelUnread = panelDerivedUnreadWorkspaceIds.union(notifications.map(\.tabId))
        let ids = notifications.map { $0.id.uuidString }
        replaceNotificationsForClear([])
        clearWorkspaceManualUnread()
        clearAllWorkspacePanelUnread(forTabIds: tabIdsToClearPanelUnread)
        clearPanelDerivedWorkspaceUnread()
        clearWorkspaceRestoredUnread()
        focusedReadIndicatorByTabId.removeAll()
        CmuxEventBus.shared.publishNotificationCleared(ids: ids, workspaceId: nil, surfaceId: nil)
        center.removeDeliveredNotificationsOffMain(withIdentifiers: ids)
        center.removePendingNotificationRequestsOffMain(withIdentifiers: ids)
    }

    func clearNotifications(
        forTabId tabId: UUID,
        surfaceId: UUID?,
        discardQueuedNotifications: Bool = true
    ) {
        if discardQueuedNotifications { TerminalMutationBus.shared.discardPendingNotifications(forTabId: tabId, surfaceId: surfaceId) }
        let hadFocusedReadIndicator = focusedReadIndicatorByTabId[tabId].map { $0 == surfaceId } ?? false
        let hadRestoredWorkspaceUnread = surfaceId == nil && restoredUnreadWorkspaceIds.contains(tabId)
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        for notification in notifications {
            if notification.matches(tabId: tabId, surfaceId: surfaceId) {
                idsToClear.append(notification.id.uuidString)
            } else {
                updated.append(notification)
            }
        }
        guard !idsToClear.isEmpty || hadFocusedReadIndicator || hadRestoredWorkspaceUnread else { return }
        if !idsToClear.isEmpty {
            replaceNotificationsForClear(updated)
        }
        if surfaceId == nil {
            setWorkspaceRestoredUnread(false, forTabId: tabId)
        }
        clearFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)
        if !idsToClear.isEmpty {
            CmuxEventBus.shared.publishNotificationCleared(ids: idsToClear, workspaceId: tabId, surfaceId: surfaceId)
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
    }

    func rebindSurfaceNotifications(fromTabId sourceTabId: UUID, toTabId destinationTabId: UUID, surfaceId: UUID) {
        guard sourceTabId != destinationTabId else { return }
        TerminalMutationBus.shared.discardPendingNotifications(forTabId: sourceTabId, surfaceId: surfaceId)

        var didMoveNotification = false
        let updated = notifications.map { notification -> TerminalNotification in
            guard notification.matches(tabId: sourceTabId, surfaceId: surfaceId) else {
                return notification
            }
            didMoveNotification = true
            return TerminalNotification(
                id: notification.id,
                tabId: destinationTabId,
                surfaceId: notification.surfaceId,
                panelId: notification.panelId,
                title: notification.title,
                subtitle: notification.subtitle,
                body: notification.body,
                createdAt: notification.createdAt,
                isRead: notification.isRead,
                paneFlash: notification.paneFlash,
                clickAction: notification.clickAction
            )
        }
        if didMoveNotification {
            notifications = updated
        }

        if focusedReadIndicatorByTabId[sourceTabId] == surfaceId {
            focusedReadIndicatorByTabId.removeValue(forKey: sourceTabId)
            if focusedReadIndicatorByTabId[destinationTabId] == nil {
                focusedReadIndicatorByTabId[destinationTabId] = surfaceId
            }
        }
    }

    func clearNotifications(forTabId tabId: UUID, discardQueuedNotifications: Bool = true) {
        if discardQueuedNotifications { TerminalMutationBus.shared.discardPendingNotifications(forTabId: tabId) }
        let hadFocusedReadIndicator = focusedReadIndicatorByTabId[tabId] != nil
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        for notification in notifications {
            if notification.tabId == tabId {
                idsToClear.append(notification.id.uuidString)
            } else {
                updated.append(notification)
            }
        }
        setWorkspaceManualUnread(false, forTabId: tabId)
        clearWorkspacePanelUnread(forTabId: tabId)
        setPanelDerivedWorkspaceUnread(false, forTabId: tabId)
        setWorkspaceRestoredUnread(false, forTabId: tabId)
        guard !idsToClear.isEmpty || hadFocusedReadIndicator else { return }
        if !idsToClear.isEmpty {
            replaceNotificationsForClear(updated)
        }
        clearFocusedReadIndicator(forTabId: tabId)
        if !idsToClear.isEmpty {
            CmuxEventBus.shared.publishNotificationCleared(ids: idsToClear, workspaceId: tabId, surfaceId: nil)
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
    }

    private func resolvedNotificationTitle(for notification: TerminalNotification) -> String {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "cmux"
        return notification.title.isEmpty ? appName : notification.title
    }

    private func scheduleUserNotification(
        _ notification: TerminalNotification,
        effects: TerminalNotificationPolicyEffects
    ) {
        guard effects.desktop else {
            playLocalNotificationFeedback(
                title: resolvedNotificationTitle(for: notification),
                subtitle: notification.subtitle,
                body: notification.body,
                effects: effects
            )
            return
        }

        ensureAuthorization(origin: .notificationDelivery) { [weak self] authorized in
            guard let self else { return }
            let content = UNMutableNotificationContent()
            content.title = self.resolvedNotificationTitle(for: notification)
            content.subtitle = notification.subtitle
            content.body = notification.body
            guard authorized else {
                self.playLocalNotificationFeedback(
                    title: content.title,
                    subtitle: content.subtitle,
                    body: content.body,
                    effects: effects
                )
                return
            }
            content.sound = effects.sound ? NotificationSoundSettings.sound() : nil
            content.categoryIdentifier = Self.categoryIdentifier
            content.userInfo = [
                "tabId": notification.tabId.uuidString,
                "notificationId": notification.id.uuidString,
            ]
            if let surfaceId = notification.surfaceId {
                content.userInfo["surfaceId"] = surfaceId.uuidString
            }
            if let clickAction = notification.clickAction {
                for (key, value) in clickAction.userInfo {
                    content.userInfo[key] = value
                }
            }

            let request = UNNotificationRequest(
                identifier: notification.id.uuidString,
                content: content,
                trigger: nil
            )

            self.center.add(request) { error in
                if let error {
                    terminalNotificationLogger.error(
                        "Failed to schedule notification error=\(error.localizedDescription, privacy: .private)"
                    )
                    Task { @MainActor [weak self] in
                        self?.playLocalNotificationFeedback(
                            title: content.title,
                            subtitle: content.subtitle,
                            body: content.body,
                            effects: effects
                        )
                    }
                } else if effects.command {
                    NotificationSoundSettings.runCustomCommand(
                        title: content.title,
                        subtitle: content.subtitle,
                        body: content.body
                    )
                }
            }
        }
    }

    private func playSuppressedNotificationFeedback(
        for notification: TerminalNotification,
        effects: TerminalNotificationPolicyEffects
    ) {
        playLocalNotificationFeedback(
            title: resolvedNotificationTitle(for: notification),
            subtitle: notification.subtitle,
            body: notification.body,
            effects: effects
        )
    }

    private func playLocalNotificationFeedback(
        title: String,
        subtitle: String,
        body: String,
        effects: TerminalNotificationPolicyEffects
    ) {
        if effects.sound {
            NotificationSoundSettings.playSelectedSound()
        }
        if effects.command {
            NotificationSoundSettings.runCustomCommand(
                title: title,
                subtitle: subtitle,
                body: body
            )
        }
    }

    private func ensureAuthorization(
        origin: AuthorizationRequestOrigin,
        _ completion: @escaping (Bool) -> Void
    ) {
        if origin == .notificationDelivery,
           let cachedDecision = Self.cachedDeliveryAuthorizationDecision(
               for: authorizationState,
               isAppActive: AppFocusState.isAppActive()
           ) {
            if !cachedDecision, authorizationState == .notDetermined {
                hasDeferredAuthorizationRequest = true
            }
            completion(cachedDecision)
            return
        }

        logAuthorization("ensure start origin=\(origin.rawValue)")
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else {
                    completion(false)
                    return
                }

                self.authorizationState = Self.authorizationState(from: settings.authorizationStatus)
                self.logAuthorization(
                    "ensure status origin=\(origin.rawValue) status=\(Self.authorizationStatusLabel(settings.authorizationStatus)) mapped=\(self.authorizationState.statusLabel) appActive=\(AppFocusState.isAppActive())"
                )
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    completion(true)
                case .denied:
                    if origin != .notificationDelivery {
                        self.logAuthorization("ensure denied origin=\(origin.rawValue) prompting_settings")
                        self.promptToEnableNotifications()
                    }
                    completion(false)
                case .notDetermined:
                    if Self.shouldDeferAutomaticAuthorizationRequest(
                        origin: origin,
                        status: settings.authorizationStatus,
                        isAppActive: AppFocusState.isAppActive()
                    ) {
                        self.logAuthorization("ensure deferred origin=\(origin.rawValue)")
                        self.hasDeferredAuthorizationRequest = true
                        completion(false)
                    } else {
                        self.requestAuthorizationIfNeeded(origin: origin, completion)
                    }
                @unknown default:
                    self.logAuthorization("ensure unknown status origin=\(origin.rawValue)")
                    completion(false)
                }
            }
        }
    }

    private func requestAuthorizationIfNeeded(
        origin: AuthorizationRequestOrigin,
        _ completion: @escaping (Bool) -> Void
    ) {
        let isAutomaticRequest = origin == .notificationDelivery
        guard Self.shouldRequestAuthorization(
            isAutomaticRequest: isAutomaticRequest,
            hasRequestedAutomaticAuthorization: hasRequestedAutomaticAuthorization
        ) else {
            logAuthorization(
                "request blocked origin=\(origin.rawValue) automatic=\(isAutomaticRequest) hasRequestedAutomatic=\(hasRequestedAutomaticAuthorization)"
            )
            completion(false)
            return
        }
        if isAutomaticRequest {
            hasRequestedAutomaticAuthorization = true
        }
        hasDeferredAuthorizationRequest = false
        logAuthorization(
            "request starting origin=\(origin.rawValue) automatic=\(isAutomaticRequest) hasRequestedAutomatic=\(hasRequestedAutomaticAuthorization)"
        )
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    self.authorizationState = .authorized
                } else {
                    self.refreshAuthorizationStatus()
                }
                self.logAuthorization(
                    "request callback origin=\(origin.rawValue) granted=\(granted) error=\(error?.localizedDescription ?? "nil") mapped=\(self.authorizationState.statusLabel)"
                )
                completion(granted)
            }
        }
    }

    private func promptToEnableNotifications() {
        guard !hasPromptedForSettings else { return }
        logAuthorization("prompt settings shown")
        hasPromptedForSettings = true
        presentNotificationSettingsPrompt(attempt: 0)
    }

    private func presentNotificationSettingsPrompt(attempt: Int) {
        guard let window = notificationSettingsWindowProvider() else {
            guard attempt < settingsPromptWindowRetryLimit else {
                // If no window is available after retries, allow a future denied callback
                // to prompt again when the app has a key/main window.
                hasPromptedForSettings = false
                return
            }
            notificationSettingsScheduler(settingsPromptWindowRetryDelay) { [weak self] in
                self?.presentNotificationSettingsPrompt(attempt: attempt + 1)
            }
            return
        }

        let alert = notificationSettingsAlertFactory()
        alert.messageText = String(localized: "dialog.enableNotifications.title", defaultValue: "Enable Notifications for cmux")
        alert.informativeText = String(localized: "dialog.enableNotifications.message", defaultValue: "Notifications are disabled for cmux. Enable them in System Settings to see alerts.")
        alert.addButton(withTitle: String(localized: "dialog.enableNotifications.openSettings", defaultValue: "Open Settings"))
        alert.addButton(withTitle: String(localized: "dialog.enableNotifications.notNow", defaultValue: "Not Now"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            self?.openNotificationSettings()
        }
    }

    static func authorizationState(from status: UNAuthorizationStatus) -> NotificationAuthorizationState {
        switch status {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .unknown
        }
    }

    static func shouldDeferAutomaticAuthorizationRequest(
        status: UNAuthorizationStatus,
        isAppActive: Bool
    ) -> Bool {
        status == .notDetermined && !isAppActive
    }

    static func shouldRequestAuthorization(
        isAutomaticRequest: Bool,
        hasRequestedAutomaticAuthorization: Bool
    ) -> Bool {
        guard isAutomaticRequest else { return true }
        return !hasRequestedAutomaticAuthorization
    }

    private static func shouldDeferAutomaticAuthorizationRequest(
        origin: AuthorizationRequestOrigin,
        status: UNAuthorizationStatus,
        isAppActive: Bool
    ) -> Bool {
        guard origin == .notificationDelivery else { return false }
        return shouldDeferAutomaticAuthorizationRequest(status: status, isAppActive: isAppActive)
    }

    private static func buildIndexes(for notifications: [TerminalNotification]) -> NotificationIndexes {
        var indexes = NotificationIndexes()
        for notification in notifications {
            if indexes.latestByTabId[notification.tabId] == nil {
                indexes.latestByTabId[notification.tabId] = notification
            }
            guard !notification.isRead else { continue }
            indexes.unreadCount += 1
            indexes.unreadCountByTabId[notification.tabId, default: 0] += 1
            indexes.unreadByTabSurface.insert(
                TabSurfaceKey(tabId: notification.tabId, surfaceId: notification.surfaceId)
            )
            if let panelId = notification.panelId, panelId != notification.surfaceId {
                indexes.unreadByTabSurface.insert(
                    TabSurfaceKey(tabId: notification.tabId, surfaceId: panelId)
                )
            }
            if indexes.latestUnreadByTabId[notification.tabId] == nil {
                indexes.latestUnreadByTabId[notification.tabId] = notification
            }
        }
        return indexes
    }

    private static func notificationSortPrecedes(_ lhs: TerminalNotification, _ rhs: TerminalNotification) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

#if DEBUG
    func configureNotificationSettingsPromptHooksForTesting(
        windowProvider: @escaping () -> NSWindow?,
        alertFactory: @escaping () -> NSAlert,
        scheduler: @escaping (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void,
        urlOpener: @escaping (URL) -> Void
    ) {
        notificationSettingsWindowProvider = windowProvider
        notificationSettingsAlertFactory = alertFactory
        notificationSettingsScheduler = scheduler
        notificationSettingsURLOpener = urlOpener
        hasPromptedForSettings = false
    }

    func resetNotificationSettingsPromptHooksForTesting() {
        notificationSettingsWindowProvider = { NSApp.keyWindow ?? NSApp.mainWindow }
        notificationSettingsAlertFactory = { NSAlert() }
        notificationSettingsScheduler = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                block()
            }
        }
        notificationSettingsURLOpener = { url in NSWorkspace.shared.open(url) }
        hasPromptedForSettings = false
    }

    func configureNotificationDeliveryHandlerForTesting(
        _ handler: @escaping (TerminalNotificationStore, TerminalNotification) -> Void
    ) {
        notificationDeliveryHandler = { store, notification, _ in
            handler(store, notification)
        }
    }

    func configureNotificationDeliveryHandlerForTesting(
        _ handler: @escaping (TerminalNotificationStore, TerminalNotification, TerminalNotificationPolicyEffects) -> Void
    ) {
        notificationDeliveryHandler = handler
    }

    func resetNotificationDeliveryHandlerForTesting() {
        notificationDeliveryHandler = { store, notification, effects in
            store.scheduleUserNotification(notification, effects: effects)
        }
    }

    func configureSuppressedNotificationFeedbackHandlerForTesting(
        _ handler: @escaping (TerminalNotificationStore, TerminalNotification) -> Void
    ) {
        suppressedNotificationFeedbackHandler = { store, notification, _ in
            handler(store, notification)
        }
    }

    func configureSuppressedNotificationFeedbackHandlerForTesting(
        _ handler: @escaping (TerminalNotificationStore, TerminalNotification, TerminalNotificationPolicyEffects) -> Void
    ) {
        suppressedNotificationFeedbackHandler = handler
    }

    func resetSuppressedNotificationFeedbackHandlerForTesting() {
        suppressedNotificationFeedbackHandler = { store, notification, effects in
            store.playSuppressedNotificationFeedback(for: notification, effects: effects)
        }
    }

    func promptToEnableNotificationsForTesting() {
        promptToEnableNotifications()
    }

    func replaceNotificationsForTesting(_ notifications: [TerminalNotification]) {
        TerminalMutationBus.shared.discardPendingNotifications()
        self.notifications = notifications
        clearWorkspaceManualUnread()
        clearPanelDerivedWorkspaceUnread()
        clearWorkspaceRestoredUnread()
        focusedReadIndicatorByTabId.removeAll()
    }
#endif

    private func refreshDockBadge() {
        let label = Self.dockBadgeLabel(
            unreadCount: unreadCount,
            isEnabled: NotificationBadgeSettings.isDockBadgeEnabled(),
            runTag: TaggedRunBadgeSettings.normalizedTag()
        )
        NSApp?.dockTile.badgeLabel = label
    }
}
