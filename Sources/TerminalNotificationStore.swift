import AppKit
import Darwin
import Foundation
import UserNotifications
import Bonsplit

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

    static func sound(defaults: UserDefaults = .standard) -> UNNotificationSound? {
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
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: value))
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

    private static func playSound(value: String, defaults: UserDefaults) {
        switch value {
        case "default":
            NSSound.beep()
        case "none":
            break
        case customFileValue:
            playCustomFileSound(defaults: defaults)
        default:
            NSSound(named: NSSound.Name(value))?.play()
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

    private static func stagedSoundDirectoryURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
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

        try fileManager.copyItem(at: normalizedSource, to: normalizedDestination)
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
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
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

enum TerminalNotificationAction: Hashable {
    case agentHookSetup(agentName: String)
}

struct AgentHookIntegration: Identifiable, Hashable, Sendable {
    let name: String
    let displayName: String
    let commandNames: [String]
    let configDir: String?
    let configFile: String?
    let configDirEnvOverride: String?
    let hookMarkers: [String]
    let currentMarkers: [String]
    let isClaudeWrapper: Bool

    var id: String { name }

    var installCommand: String {
        if isClaudeWrapper {
            return "cmux settings open --section automation"
        }
        return "cmux hooks \(name) install"
    }
}

enum AgentHookIntegrationStatus: Equatable {
    case enabled
    case disabled
    case installed(path: String)
    case updateAvailable(path: String)
    case notInstalled(path: String?)
    case unreadable(path: String)

    var isActive: Bool {
        switch self {
        case .enabled, .installed:
            return true
        case .disabled, .updateAvailable, .notInstalled, .unreadable:
            return false
        }
    }

    var isUpdateAvailable: Bool {
        if case .updateAvailable = self {
            return true
        }
        return false
    }
}

struct AgentHookInstallResult {
    let succeeded: Bool
    let message: String
}

struct AgentHookDiffResult {
    let succeeded: Bool
    let message: String
    let diff: String
}

enum AgentHookIntegrationSettings {
    static let promptEnabledKey = "agentHookSetupPromptEnabled"
    static let defaultPromptEnabled = true
    static let statusDidChangeNotification = Notification.Name("cmux.agentHookIntegration.statusDidChange")

    private static let promptCooldown: TimeInterval = 24 * 60 * 60
    private static let configFileWatcher = ConfigFileWatcher()

    static let allAgents: [AgentHookIntegration] = [
        AgentHookIntegration(
            name: "claude",
            displayName: "Claude Code",
            commandNames: ["claude"],
            configDir: nil,
            configFile: nil,
            configDirEnvOverride: nil,
            hookMarkers: [],
            currentMarkers: [],
            isClaudeWrapper: true
        ),
        AgentHookIntegration(
            name: "codex",
            displayName: "Codex",
            commandNames: ["codex"],
            configDir: ".codex",
            configFile: "hooks.json",
            configDirEnvOverride: "CODEX_HOME",
            hookMarkers: ["cmux hooks codex", "cmux codex-hook"],
            currentMarkers: ["CMUX_AGENT_HOOK_VERSION=1"],
            isClaudeWrapper: false
        ),
        AgentHookIntegration(
            name: "opencode",
            displayName: "OpenCode",
            commandNames: ["opencode", "open-code"],
            configDir: ".config/opencode",
            configFile: "plugins/cmux-session.js",
            configDirEnvOverride: "OPENCODE_CONFIG_DIR",
            hookMarkers: ["cmux-opencode-session-plugin-marker", "cmux hooks opencode"],
            currentMarkers: ["cmux-opencode-session-plugin-marker v1"],
            isClaudeWrapper: false
        ),
        AgentHookIntegration(
            name: "cursor",
            displayName: "Cursor",
            commandNames: ["cursor"],
            configDir: ".cursor",
            configFile: "hooks.json",
            configDirEnvOverride: nil,
            hookMarkers: ["cmux hooks cursor"],
            currentMarkers: ["CMUX_AGENT_HOOK_VERSION=1"],
            isClaudeWrapper: false
        ),
        AgentHookIntegration(
            name: "gemini",
            displayName: "Gemini",
            commandNames: ["gemini"],
            configDir: ".gemini",
            configFile: "settings.json",
            configDirEnvOverride: nil,
            hookMarkers: ["cmux hooks gemini"],
            currentMarkers: ["CMUX_AGENT_HOOK_VERSION=1"],
            isClaudeWrapper: false
        ),
        AgentHookIntegration(
            name: "copilot",
            displayName: "Copilot",
            commandNames: ["copilot"],
            configDir: ".copilot",
            configFile: "config.json",
            configDirEnvOverride: nil,
            hookMarkers: ["cmux hooks copilot"],
            currentMarkers: ["CMUX_AGENT_HOOK_VERSION=1"],
            isClaudeWrapper: false
        ),
        AgentHookIntegration(
            name: "codebuddy",
            displayName: "CodeBuddy",
            commandNames: ["codebuddy"],
            configDir: ".codebuddy",
            configFile: "settings.json",
            configDirEnvOverride: nil,
            hookMarkers: ["cmux hooks codebuddy"],
            currentMarkers: ["CMUX_AGENT_HOOK_VERSION=1"],
            isClaudeWrapper: false
        ),
        AgentHookIntegration(
            name: "factory",
            displayName: "Factory",
            commandNames: ["factory"],
            configDir: ".factory",
            configFile: "settings.json",
            configDirEnvOverride: nil,
            hookMarkers: ["cmux hooks factory"],
            currentMarkers: ["CMUX_AGENT_HOOK_VERSION=1"],
            isClaudeWrapper: false
        ),
        AgentHookIntegration(
            name: "qoder",
            displayName: "Qoder",
            commandNames: ["qoder"],
            configDir: ".qoder",
            configFile: "settings.json",
            configDirEnvOverride: nil,
            hookMarkers: ["cmux hooks qoder"],
            currentMarkers: ["CMUX_AGENT_HOOK_VERSION=1"],
            isClaudeWrapper: false
        ),
    ]

    static func promptEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: promptEnabledKey) == nil {
            return defaultPromptEnabled
        }
        return defaults.bool(forKey: promptEnabledKey)
    }

    static func setPromptEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: promptEnabledKey)
        NotificationCenter.default.post(name: statusDidChangeNotification, object: nil)
    }

    static func agent(named name: String) -> AgentHookIntegration? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allAgents.first { agent in
            agent.name == normalized || agent.commandNames.contains(normalized)
        }
    }

    static func status(for agent: AgentHookIntegration, defaults: UserDefaults = .standard) -> AgentHookIntegrationStatus {
        configFileWatcher.startIfNeeded()

        if agent.isClaudeWrapper {
            return ClaudeCodeIntegrationSettings.hooksEnabled(defaults: defaults) ? .enabled : .disabled
        }

        guard let path = configFilePath(for: agent) else {
            return .notInstalled(path: nil)
        }

        guard FileManager.default.fileExists(atPath: path) else {
            return .notInstalled(path: path)
        }
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .unreadable(path: path)
        }
        if agent.currentMarkers.contains(where: { contents.contains($0) }) {
            return .installed(path: path)
        }
        if agent.hookMarkers.contains(where: { contents.contains($0) }) {
            return .updateAvailable(path: path)
        }
        return .notInstalled(path: path)
    }

    static func statusLabel(for status: AgentHookIntegrationStatus) -> String {
        switch status {
        case .enabled:
            return String(localized: "settings.automation.agentHooks.status.enabled", defaultValue: "Enabled")
        case .disabled:
            return String(localized: "settings.automation.agentHooks.status.disabled", defaultValue: "Disabled")
        case .installed:
            return String(localized: "settings.automation.agentHooks.status.installed", defaultValue: "Installed")
        case .updateAvailable:
            return String(localized: "settings.automation.agentHooks.status.updateAvailable", defaultValue: "Update available")
        case .notInstalled:
            return String(localized: "settings.automation.agentHooks.status.notInstalled", defaultValue: "Not installed")
        case .unreadable:
            return String(localized: "settings.automation.agentHooks.status.unknown", defaultValue: "Unknown")
        }
    }

    static func statusSubtitle(for agent: AgentHookIntegration, status: AgentHookIntegrationStatus) -> String {
        switch status {
        case .enabled:
            return String(localized: "settings.automation.agentHooks.status.claudeEnabled", defaultValue: "cmux wraps the claude command in cmux terminals.")
        case .disabled:
            return String(localized: "settings.automation.agentHooks.status.claudeDisabled", defaultValue: "Claude Code runs without cmux hooks.")
        case .installed(let path):
            return String(localized: "settings.automation.agentHooks.status.installedAt", defaultValue: "cmux hooks found in \(path).")
        case .updateAvailable:
            return String(localized: "settings.automation.agentHooks.status.updateAvailable.subtitle", defaultValue: "cmux hooks are installed, but this app has a newer hook script.")
        case .notInstalled:
            return String(localized: "settings.automation.agentHooks.status.notInstalled.subtitle", defaultValue: "No cmux hooks found.")
        case .unreadable(let path):
            return String(localized: "settings.automation.agentHooks.status.unreadable", defaultValue: "Could not read \(path).")
        }
    }

    @MainActor
    static func showSetupPromptIfNeeded(agentName: String, tabId: UUID, surfaceId: UUID?) {
        guard promptEnabled(),
              let agent = agent(named: agentName) else {
            return
        }
        let currentStatus = status(for: agent)
        guard !currentStatus.isActive else {
            return
        }
        guard shouldShowPrompt(for: agent, status: currentStatus) else {
            return
        }
        guard !TerminalNotificationStore.shared.hasAgentHookSetupNotification(for: agent.name) else {
            return
        }

        TerminalNotificationStore.shared.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: currentStatus.isUpdateAvailable
                ? String(localized: "agentHooks.nudge.updateTitle", defaultValue: "Update \(agent.displayName) hooks")
                : String(localized: "agentHooks.nudge.title", defaultValue: "Install \(agent.displayName) hooks"),
            subtitle: String(localized: "agentHooks.nudge.subtitle", defaultValue: "Notifications and session restore"),
            body: currentStatus.isUpdateAvailable
                ? String(localized: "agentHooks.nudge.updateBody", defaultValue: "cmux has a newer hook script for notifications and session restore.")
                : String(localized: "agentHooks.nudge.body", defaultValue: "Hooks let cmux show agent notifications and restore sessions after cmux restarts."),
            action: .agentHookSetup(agentName: agent.name)
        )
        AppDelegate.shared?.toggleNotificationsPopover(animated: true)
    }

    static func snoozePrompt(agentName: String, defaults: UserDefaults = .standard) {
        guard let agent = agent(named: agentName) else { return }
        let currentStatus = status(for: agent, defaults: defaults)
        markPromptSnoozed(for: agent, status: currentStatus, defaults: defaults)
    }

    static func installHooks(for agent: AgentHookIntegration, completion: @escaping (AgentHookInstallResult) -> Void) {
        if agent.isClaudeWrapper {
            UserDefaults.standard.set(true, forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
            NotificationCenter.default.post(name: statusDidChangeNotification, object: nil)
            completion(AgentHookInstallResult(
                succeeded: true,
                message: String(localized: "settings.automation.agentHooks.status.claudeEnabled", defaultValue: "cmux wraps the claude command in cmux terminals.")
            ))
            return
        }

        let launch = hookInstallLaunch(for: agent)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runInstallCommand(
                executableURL: launch.executableURL,
                arguments: launch.arguments,
                environment: nil,
                fallbackCommand: agent.installCommand
            )
            DispatchQueue.main.async {
                configFileWatcher.refreshWatchedPaths()
                NotificationCenter.default.post(name: statusDidChangeNotification, object: nil)
                completion(result)
            }
        }
    }

    static func diffHooks(for agent: AgentHookIntegration, completion: @escaping (AgentHookDiffResult) -> Void) {
        if agent.isClaudeWrapper {
            completion(AgentHookDiffResult(
                succeeded: true,
                message: "",
                diff: String(localized: "agentHooks.diff.claude", defaultValue: "Claude Code uses the cmux wrapper in cmux terminals. No config file changes are needed.")
            ))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = buildHookDiff(for: agent)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private static func configDirectoryPath(for agent: AgentHookIntegration) -> String? {
        guard let configDir = agent.configDir else {
            return nil
        }
        if let envKey = agent.configDirEnvOverride,
           let envValue = ProcessInfo.processInfo.environment[envKey],
           !envValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NSString(string: envValue).expandingTildeInPath
        }
        return NSString(string: "~/\(configDir)").expandingTildeInPath
    }

    private static func configFilePath(for agent: AgentHookIntegration) -> String? {
        guard let directory = configDirectoryPath(for: agent),
              let configFile = agent.configFile else {
            return nil
        }
        return (directory as NSString).appendingPathComponent(configFile)
    }

    private static func shouldShowPrompt(
        for agent: AgentHookIntegration,
        status: AgentHookIntegrationStatus,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let key = lastPromptKey(for: agent, status: status)
        let lastSnoozed = defaults.double(forKey: key)
        guard lastSnoozed > 0 else { return true }
        return Date().timeIntervalSince1970 - lastSnoozed >= promptCooldown
    }

    private static func markPromptSnoozed(
        for agent: AgentHookIntegration,
        status: AgentHookIntegrationStatus,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(Date().timeIntervalSince1970, forKey: lastPromptKey(for: agent, status: status))
    }

    private static func lastPromptKey(for agent: AgentHookIntegration, status: AgentHookIntegrationStatus) -> String {
        let kind = status.isUpdateAvailable ? "update" : "install"
        return "agentHookSetupPromptSnoozedAt.\(agent.name).\(kind)"
    }

    private static func hookInstallLaunch(for agent: AgentHookIntegration) -> (executableURL: URL, arguments: [String]) {
        if let bundledCLIURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
           FileManager.default.isExecutableFile(atPath: bundledCLIURL.path) {
            return (bundledCLIURL, ["hooks", agent.name, "install", "--yes"])
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["cmux", "hooks", agent.name, "install", "--yes"])
    }

    private static func buildHookDiff(for agent: AgentHookIntegration) -> AgentHookDiffResult {
        let fm = FileManager.default
        let tempHome = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-agent-hook-diff-\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tempHome) }

            guard let configDir = agent.configDir else {
                return AgentHookDiffResult(
                    succeeded: false,
                    message: String(localized: "agentHooks.diff.failed", defaultValue: "Could not prepare hook diff."),
                    diff: ""
                )
            }

            let originalConfigDir = expandedHomePath(configDir)
            let tempConfigDir = tempHome.appendingPathComponent(configDir, isDirectory: true)
            try fm.createDirectory(at: tempConfigDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: originalConfigDir.path) {
                try fm.copyItem(at: originalConfigDir, to: tempConfigDir)
            } else {
                try fm.createDirectory(at: tempConfigDir, withIntermediateDirectories: true)
            }

            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = tempHome.path
            if let envKey = agent.configDirEnvOverride {
                environment[envKey] = tempConfigDir.path
            }

            let launch = hookInstallLaunch(for: agent)
            let installResult = runInstallCommand(
                executableURL: launch.executableURL,
                arguments: launch.arguments,
                environment: environment,
                fallbackCommand: agent.installCommand
            )
            guard installResult.succeeded else {
                return AgentHookDiffResult(succeeded: false, message: installResult.message, diff: "")
            }

            let relativePaths = diffRelativePaths(for: agent)
            let diffs = relativePaths.compactMap { relativePath in
                let oldURL = URL(fileURLWithPath: NSString(string: "~/\(relativePath)").expandingTildeInPath)
                let newURL = tempHome.appendingPathComponent(relativePath)
                return unifiedDiff(relativePath: relativePath, oldURL: oldURL, newURL: newURL)
            }
            let diff = diffs.joined(separator: "\n")
            if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return AgentHookDiffResult(
                    succeeded: true,
                    message: String(localized: "agentHooks.diff.noChanges", defaultValue: "No file changes needed."),
                    diff: String(localized: "agentHooks.diff.noChanges", defaultValue: "No file changes needed.")
                )
            }
            return AgentHookDiffResult(succeeded: true, message: "", diff: diff)
        } catch {
            return AgentHookDiffResult(
                succeeded: false,
                message: String(localized: "agentHooks.diff.failed", defaultValue: "Could not prepare hook diff."),
                diff: ""
            )
        }
    }

    private static func expandedHomePath(_ relativePath: String) -> URL {
        URL(fileURLWithPath: NSString(string: "~/\(relativePath)").expandingTildeInPath)
    }

    private static func diffRelativePaths(for agent: AgentHookIntegration) -> [String] {
        guard let configDir = agent.configDir,
              let configFile = agent.configFile else {
            return []
        }
        var paths = ["\(configDir)/\(configFile)"]
        if agent.name == "codex" {
            paths.append("\(configDir)/config.toml")
        }
        return paths
    }

    private static func unifiedDiff(relativePath: String, oldURL: URL, newURL: URL) -> String? {
        let oldText = (try? String(contentsOf: oldURL, encoding: .utf8)) ?? ""
        let newText = (try? String(contentsOf: newURL, encoding: .utf8)) ?? ""
        guard oldText != newText else { return nil }

        let oldLines = oldText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = newText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lines = [
            "--- ~/\(relativePath)",
            "+++ ~/\(relativePath)",
            "@@",
        ]
        lines.append(contentsOf: oldLines.map { "-\($0)" })
        lines.append(contentsOf: newLines.map { "+\($0)" })
        return lines.joined(separator: "\n")
    }

    private static func watchedConfigFilePaths() -> Set<String> {
        var paths: Set<String> = []
        for agent in allAgents where !agent.isClaudeWrapper {
            if let configFilePath = configFilePath(for: agent) {
                paths.insert(configFilePath)
            }
            if agent.name == "codex",
               let configDirectoryPath = configDirectoryPath(for: agent) {
                paths.insert((configDirectoryPath as NSString).appendingPathComponent("config.toml"))
            }
        }
        return paths
    }

    private static func watchedConfigPaths() -> Set<String> {
        let fm = FileManager.default
        var paths: Set<String> = []
        for filePath in watchedConfigFilePaths() {
            let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
            if fm.fileExists(atPath: fileURL.path) {
                paths.insert(fileURL.path)
            }
            if let parentURL = nearestExistingAncestor(for: fileURL.deletingLastPathComponent()) {
                paths.insert(parentURL.path)
            }
        }
        return paths
    }

    private static func nearestExistingAncestor(for url: URL) -> URL? {
        let fm = FileManager.default
        var current = url.standardizedFileURL
        while true {
            if fm.fileExists(atPath: current.path) {
                return current
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
    }

    private final class ConfigFileWatcher {
        private let queue = DispatchQueue(label: "com.cmuxterm.agent-hook-config-watcher", qos: .utility)
        private var isStarted = false
        private var watchedPaths: Set<String> = []
        private var sources: [String: DispatchSourceFileSystemObject] = [:]

        func startIfNeeded() {
            queue.async { [weak self] in
                guard let self, !isStarted else { return }
                isStarted = true
                rebuildWatchedPaths()
            }
        }

        func refreshWatchedPaths() {
            queue.async { [weak self] in
                guard let self, isStarted else { return }
                rebuildWatchedPaths()
            }
        }

        private func rebuildWatchedPaths() {
            let nextPaths = AgentHookIntegrationSettings.watchedConfigPaths()
            for path in watchedPaths.subtracting(nextPaths) {
                sources.removeValue(forKey: path)?.cancel()
            }
            for path in nextPaths.subtracting(watchedPaths) {
                startWatching(path: path)
            }
            watchedPaths = Set(sources.keys)
        }

        private func startWatching(path: String) {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.handleChange()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            sources[path] = source
            source.resume()
        }

        private func handleChange() {
            rebuildWatchedPaths()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: AgentHookIntegrationSettings.statusDidChangeNotification, object: nil)
            }
        }
    }

    private static func runInstallCommand(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        fallbackCommand: String
    ) -> AgentHookInstallResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return AgentHookInstallResult(
                succeeded: false,
                message: String(localized: "agentHooks.prompt.installFailed", defaultValue: "Could not install hooks. Run \(fallbackCommand) in a terminal.")
            )
        }

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let detail = errorOutput.isEmpty ? output : errorOutput
            if detail.isEmpty {
                return AgentHookInstallResult(
                    succeeded: false,
                    message: String(localized: "agentHooks.prompt.installFailed", defaultValue: "Could not install hooks. Run \(fallbackCommand) in a terminal.")
                )
            }
            return AgentHookInstallResult(succeeded: false, message: detail)
        }

        return AgentHookInstallResult(
            succeeded: true,
            message: String(localized: "agentHooks.prompt.installSucceeded", defaultValue: "Hooks installed.")
        )
    }
}

struct TerminalNotification: Identifiable, Hashable {
    let id: UUID
    let tabId: UUID
    let surfaceId: UUID?
    let title: String
    let subtitle: String
    let body: String
    let action: TerminalNotificationAction?
    let createdAt: Date
    var isRead: Bool

    init(
        id: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String,
        action: TerminalNotificationAction? = nil,
        createdAt: Date,
        isRead: Bool
    ) {
        self.id = id
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.action = action
        self.createdAt = createdAt
        self.isRead = isRead
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
            let nextMenuSnapshot = NotificationMenuSnapshotBuilder.make(notifications: notifications)
            if notificationMenuSnapshot != nextMenuSnapshot {
                notificationMenuSnapshot = nextMenuSnapshot
            }
            refreshDockBadge()
        }
    }
    @Published private(set) var notificationMenuSnapshot = NotificationMenuSnapshotBuilder.make(notifications: [])
    @Published private(set) var focusedReadIndicatorByTabId: [UUID: UUID] = [:]
    @Published private(set) var authorizationState: NotificationAuthorizationState = .unknown

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
    private var notificationDeliveryHandler: (TerminalNotificationStore, TerminalNotification) -> Void = {
        store,
        notification in
        store.scheduleUserNotification(notification)
    }
    private var suppressedNotificationFeedbackHandler: (TerminalNotificationStore, TerminalNotification) -> Void = {
        store,
        notification in
        store.playSuppressedNotificationFeedback(for: notification)
    }
    private var lastNotificationDateByCooldownKey: [String: Date] = [:]
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
        indexes.unreadCount
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
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
            return
        }
        logAuthorization("open settings url=\(url.absoluteString)")
        notificationSettingsURLOpener(url)
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

    func unreadCount(forTabId tabId: UUID) -> Int {
        indexes.unreadCountByTabId[tabId] ?? 0
    }

    func hasUnreadNotification(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        indexes.unreadByTabSurface.contains(TabSurfaceKey(tabId: tabId, surfaceId: surfaceId))
    }

    func hasVisibleNotificationIndicator(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId) ||
            focusedReadIndicatorByTabId[tabId] == surfaceId
    }

    func latestNotification(forTabId tabId: UUID) -> TerminalNotification? {
        indexes.latestByTabId[tabId]
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
        action: TerminalNotificationAction? = nil
    ) {
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
            return
        }

        var updated = notifications
        var idsToClear: [String] = []
        updated.removeAll { existing in
            guard existing.tabId == tabId, existing.surfaceId == surfaceId else { return false }
            idsToClear.append(existing.id.uuidString)
            return true
        }

        if let existingIndicatorSurfaceId = focusedReadIndicatorByTabId[tabId],
           existingIndicatorSurfaceId != surfaceId {
            focusedReadIndicatorByTabId.removeValue(forKey: tabId)
        }

        let isActiveTab = AppDelegate.shared?.tabManager?.selectedTabId == tabId
        let focusedSurfaceId = AppDelegate.shared?.tabManager?.focusedSurfaceId(for: tabId)
        let isFocusedSurface = surfaceId == nil || focusedSurfaceId == surfaceId
        let isFocusedPanel = isActiveTab && isFocusedSurface
        let isAppFocused = AppFocusState.isAppFocused()
        let shouldSuppressExternalDelivery = isAppFocused && isFocusedPanel
        if shouldSuppressExternalDelivery {
            setFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)
        }

        if WorkspaceAutoReorderSettings.isEnabled() {
            AppDelegate.shared?.tabManager?.moveTabToTopForNotification(tabId)
        }

        let notification = TerminalNotification(
            id: UUID(),
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            action: action,
            createdAt: now,
            isRead: false
        )
        updated.insert(notification, at: 0)
        notifications = updated
        if let cooldownKey, resolvedCooldownInterval != nil {
            lastNotificationDateByCooldownKey[cooldownKey] = now
        }
        if !idsToClear.isEmpty {
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
        if shouldSuppressExternalDelivery {
            suppressedNotificationFeedbackHandler(self, notification)
        } else {
            notificationDeliveryHandler(self, notification)
        }
    }

    func hasAgentHookSetupNotification(for agentName: String) -> Bool {
        notifications.contains { notification in
            if case .agentHookSetup(let existingAgentName) = notification.action {
                return existingAgentName == agentName
            }
            return false
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
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        }
    }

    func markRead(forTabId tabId: UUID, surfaceId: UUID?) {
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if updated[index].tabId == tabId,
               updated[index].surfaceId == surfaceId,
               !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
    }

    func markUnread(forTabId tabId: UUID) {
        var updated = notifications
        var didChange = false
        for index in updated.indices {
            if updated[index].tabId == tabId, updated[index].isRead {
                updated[index].isRead = false
                didChange = true
            }
        }
        if didChange {
            notifications = updated
        }
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
        for index in updated.indices {
            if !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
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

    func clearAll(discardQueuedNotifications: Bool = true) {
        if discardQueuedNotifications {
            TerminalMutationBus.shared.discardPendingNotifications()
        }
        guard !notifications.isEmpty || !focusedReadIndicatorByTabId.isEmpty else { return }
        let ids = notifications.map { $0.id.uuidString }
        notifications.removeAll()
        focusedReadIndicatorByTabId.removeAll()
        center.removeDeliveredNotificationsOffMain(withIdentifiers: ids)
        center.removePendingNotificationRequestsOffMain(withIdentifiers: ids)
    }

    func clearNotifications(
        forTabId tabId: UUID,
        surfaceId: UUID?,
        discardQueuedNotifications: Bool = true
    ) {
        if discardQueuedNotifications {
            TerminalMutationBus.shared.discardPendingNotifications(forTabId: tabId, surfaceId: surfaceId)
        }
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        for notification in notifications {
            if notification.tabId == tabId, notification.surfaceId == surfaceId {
                idsToClear.append(notification.id.uuidString)
            } else {
                updated.append(notification)
            }
        }
        guard !idsToClear.isEmpty else { return }
        notifications = updated
        clearFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)
        center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
    }

    func clearNotifications(forTabId tabId: UUID, discardQueuedNotifications: Bool = true) {
        if discardQueuedNotifications {
            TerminalMutationBus.shared.discardPendingNotifications(forTabId: tabId)
        }
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
        guard !idsToClear.isEmpty else { return }
        notifications = updated
        clearFocusedReadIndicator(forTabId: tabId)
        center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
    }

    private func resolvedNotificationTitle(for notification: TerminalNotification) -> String {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "cmux"
        return notification.title.isEmpty ? appName : notification.title
    }

    private func scheduleUserNotification(_ notification: TerminalNotification) {
        ensureAuthorization(origin: .notificationDelivery) { [weak self] authorized in
            guard let self, authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = self.resolvedNotificationTitle(for: notification)
            content.subtitle = notification.subtitle
            content.body = notification.body
            content.sound = NotificationSoundSettings.sound()
            content.categoryIdentifier = Self.categoryIdentifier
            content.userInfo = [
                "tabId": notification.tabId.uuidString,
                "notificationId": notification.id.uuidString,
            ]
            if let surfaceId = notification.surfaceId {
                content.userInfo["surfaceId"] = surfaceId.uuidString
            }

            let request = UNNotificationRequest(
                identifier: notification.id.uuidString,
                content: content,
                trigger: nil
            )

            self.center.add(request) { error in
                if let error {
                    NSLog("Failed to schedule notification: \(error)")
                } else {
                    NotificationSoundSettings.runCustomCommand(
                        title: content.title,
                        subtitle: content.subtitle,
                        body: content.body
                    )
                }
            }
        }
    }

    private func playSuppressedNotificationFeedback(for notification: TerminalNotification) {
        NotificationSoundSettings.playSelectedSound()
        NotificationSoundSettings.runCustomCommand(
            title: resolvedNotificationTitle(for: notification),
            subtitle: notification.subtitle,
            body: notification.body
        )
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
            if indexes.latestUnreadByTabId[notification.tabId] == nil {
                indexes.latestUnreadByTabId[notification.tabId] = notification
            }
        }
        return indexes
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
        notificationSettingsURLOpener = { url in
            NSWorkspace.shared.open(url)
        }
        hasPromptedForSettings = false
    }

    func configureNotificationDeliveryHandlerForTesting(
        _ handler: @escaping (TerminalNotificationStore, TerminalNotification) -> Void
    ) {
        notificationDeliveryHandler = handler
    }

    func resetNotificationDeliveryHandlerForTesting() {
        notificationDeliveryHandler = { store, notification in
            store.scheduleUserNotification(notification)
        }
    }

    func configureSuppressedNotificationFeedbackHandlerForTesting(
        _ handler: @escaping (TerminalNotificationStore, TerminalNotification) -> Void
    ) {
        suppressedNotificationFeedbackHandler = handler
    }

    func resetSuppressedNotificationFeedbackHandlerForTesting() {
        suppressedNotificationFeedbackHandler = { store, notification in
            store.playSuppressedNotificationFeedback(for: notification)
        }
    }

    func promptToEnableNotificationsForTesting() {
        promptToEnableNotifications()
    }

    func replaceNotificationsForTesting(_ notifications: [TerminalNotification]) {
        TerminalMutationBus.shared.discardPendingNotifications()
        self.notifications = notifications
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
