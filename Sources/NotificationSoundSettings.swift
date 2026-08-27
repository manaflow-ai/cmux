import AppKit
import CmuxFoundation
import CmuxSettings
import Foundation
import os
import UserNotifications

// Notification sound selection, Focus/DND suppression, fallback playback,
// and notification custom-command execution. File staging and codec
// conversion live in NotificationSoundSettings+CustomSoundStaging so this
// facade remains a small, stable seam for the rest of the app and tests.

nonisolated private let notificationSoundLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "notification-sound"
)

nonisolated enum NotificationSoundSettings {
    private static let catalog = NotificationsCatalogSection()

    static let key = catalog.sound.userDefaultsKey
    static let defaultValue = catalog.sound.defaultValue
    static let customFileValue = NotificationSoundOverride.customFileValue
    static let customFilePathKey = catalog.customSoundFilePath.userDefaultsKey
    static let defaultCustomFilePath = catalog.customSoundFilePath.defaultValue
    static let customCommandKey = catalog.command.userDefaultsKey
    static let defaultCustomCommand = catalog.command.defaultValue

    private static let activePlaybackSoundsLock = NSLock()
    private static var activePlaybackSounds: [ObjectIdentifier: NSSound] = [:]
    private static var activeCustomCommandCount = 0
    private static let activePlaybackSoundDelegate = ActivePlaybackSoundDelegate()
    private static let dndAssertionQueue = DispatchQueue(
        label: "com.cmuxterm.notification-dnd-assertion",
        qos: .utility
    )
    private static let customCommandQueue = DispatchQueue(
        label: "com.cmuxterm.notification-custom-command",
        qos: .utility,
        attributes: .concurrent
    )
    private static let maximumCustomCommandProcesses = 32
    private static let maximumCustomCommandTimeoutNanoseconds: UInt64 = 300_000_000_000

    /// NSSound may invoke its delegate after playback on a non-main thread.
    /// The delegate therefore only calls the lock-protected release helper;
    /// playback ownership is intentionally not MainActor-isolated.
    private final class ActivePlaybackSoundDelegate: NSObject, NSSoundDelegate {
        func sound(_ sound: NSSound, didFinishPlaying finishedPlaying: Bool) {
            NotificationSoundSettings.releaseActivePlaybackSound(sound)
        }
    }

    static let systemSounds: [(label: String, value: String)] = {
        let catalog = NotificationSoundOptionCatalog()
        return catalog.options.map {
            (catalog.localizedLabel(for: $0), $0.value)
        }
    }()

    static func sound(
        defaults: UserDefaults = .standard,
        systemSoundStagingDirectory: URL? = nil,
        preparationPolicy: NotificationSoundPreparationPolicy = .prepareIfNeeded
    ) async -> UNNotificationSound? {
        let value = defaults.string(forKey: key) ?? defaultValue
        switch value {
        case defaultValue:
            return .default
        case "none":
            return nil
        case customFileValue:
            guard let customSoundName = await stagedCustomSoundName(
                defaults: defaults,
                stagingDirectory: systemSoundStagingDirectory,
                preparationPolicy: preparationPolicy
            ) else {
                return nil
            }
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: customSoundName))
        default:
            guard let stagedSystemSoundName = await stagedSystemSoundName(
                for: value,
                stagingDirectory: systemSoundStagingDirectory,
                preparationPolicy: preparationPolicy
            ) else {
                notificationSoundLogger.error(
                    "Notification system sound unavailable; falling back to default value=\(value, privacy: .private)"
                )
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
        (defaults.string(forKey: key) ?? defaultValue) == "none"
    }

    static func isCustomFileSelected(defaults: UserDefaults = .standard) -> Bool {
        (defaults.string(forKey: key) ?? defaultValue) == customFileValue
    }

    static func stagedCustomSoundName(
        defaults: UserDefaults = .standard,
        stagingDirectory: URL? = nil,
        preparationPolicy: NotificationSoundPreparationPolicy = .prepareIfNeeded
    ) async -> String? {
        let rawPath = defaults.string(forKey: customFilePathKey) ?? defaultCustomFilePath
        return await stagedCustomSoundName(
            path: rawPath,
            stagingDirectory: stagingDirectory,
            preparationPolicy: preparationPolicy
        )
    }

    /// Stages an explicitly supplied custom path (used by one matrix cell)
    /// through the same copy/transcode/cache machinery as the global picker.
    static func stagedCustomSoundName(
        path rawPath: String,
        stagingDirectory: URL? = nil,
        preparationPolicy: NotificationSoundPreparationPolicy = .prepareIfNeeded
    ) async -> String? {
        if preparationPolicy == .readyOnly {
            return await stagedNameIfReady(
                path: rawPath,
                stagingDirectory: stagingDirectory
            )
        }
        return await stagedName(
            path: rawPath,
            stagingDirectory: stagingDirectory
        )
    }

    static func prepareCustomFileForNotifications(
        path: String,
        stagingDirectory: URL? = nil
    ) async -> Result<String, CustomSoundPreparationIssue> {
        await prepare(
            path: path,
            stagingDirectory: stagingDirectory
        )
    }

    static func customFileURL(defaults: UserDefaults = .standard) -> URL? {
        expandedURL(
            for: defaults.string(forKey: customFilePathKey) ?? defaultCustomFilePath
        )
    }

    /// Live Do Not Disturb assertion store written by the Focus daemon.
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

    /// Returns true when the Focus assertion store contains a live assertion.
    /// Reads fail open so a protected or temporarily unavailable store never
    /// disables notification feedback permanently.
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
            guard let records = entry["storeAssertionRecords"] as? [Any] else { return false }
            return !records.isEmpty
        }
    }

    /// Checks Focus off the main queue, then resolves/stages the selected
    /// sound before hopping to AppKit for playback. This keeps file I/O and
    /// `.m4r` conversion out of notification delivery's main-actor turn.
    static func playSelectedSound(
        defaults: UserDefaults = .standard,
        assertionsFileURL: URL = defaultAssertionsFileURL,
        context: NotificationSoundOverrideContext? = nil,
        playbackAdmission: (@MainActor @Sendable () -> Bool)? = nil
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        let snapshot = await cachedResolutionSnapshot(
            context: context,
            defaults: defaults
        )
        let suppressedAtAdmission = await activeFocusSuppression(
            assertionsFileURL: assertionsFileURL
        )
        guard !Task.isCancelled, !suppressedAtAdmission else { return false }

        let prepared = await prepareNotificationSound(snapshot: snapshot)
        // Custom transcoding can take long enough for Focus to change.
        // Re-read the live assertion immediately before direct playback so
        // preparation cannot punch a stale decision through DND.
        guard !Task.isCancelled,
              !(await activeFocusSuppression(assertionsFileURL: assertionsFileURL)) else {
            return false
        }
        guard !Task.isCancelled else { return false }
        return await MainActor.run {
            guard !Task.isCancelled,
                  playbackAdmission?() ?? true else { return false }
            return playPreparedSound(prepared)
        }
    }

    @discardableResult
    static func previewSound(value: String, defaults: UserDefaults = .standard) async -> Bool {
        await previewSound(
            selection: ResolvedNotificationSoundPlaybackSelection(
                value: value,
                customFilePath: defaults.string(forKey: customFilePathKey)
            )
        )
    }

    @discardableResult
    static func previewSound(
        value: String,
        customFilePath: String,
        defaults: UserDefaults = .standard
    ) async -> Bool {
        await previewSound(
            selection: ResolvedNotificationSoundPlaybackSelection(
                value: value,
                customFilePath: customFilePath
            )
        )
    }

    private static func previewSound(
        selection: ResolvedNotificationSoundPlaybackSelection
    ) async -> Bool {
        let snapshot = NotificationSoundResolutionSnapshot(
            globalSelection: selection,
            overrideSelection: nil
        )
        let prepared = await prepareNotificationSound(snapshot: snapshot)
        guard !Task.isCancelled else { return false }
        return await MainActor.run {
            guard !Task.isCancelled else { return false }
            return playPreparedSound(prepared)
        }
    }

    private static func activeFocusSuppression(
        assertionsFileURL: URL
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            dndAssertionQueue.async {
                let suppressed = isSuppressedByActiveFocus(
                    assertionsFileURL: assertionsFileURL
                )
#if DEBUG
                let storeReadable = (try? Data(contentsOf: assertionsFileURL)) != nil
                cmuxDebugLog(
                    "notification.sound.focusGate suppressed=\(suppressed ? 1 : 0) storeReadable=\(storeReadable ? 1 : 0)"
                )
#endif
                continuation.resume(returning: suppressed)
            }
        }
    }

    static func stagedSystemSoundFileName(for value: String) -> String {
        systemSoundFileName(for: value)
    }

    static func stagedSystemSoundName(
        for value: String,
        sourceDirectory: URL = systemSoundDirectoryURL,
        stagingDirectory: URL? = nil,
        preparationPolicy _: NotificationSoundPreparationPolicy = .prepareIfNeeded
    ) async -> String? {
        // System sounds are already decoded by macOS and only need a small
        // file copy into the notification daemon's Sounds directory. Allow
        // that cheap preparation even on the ready-only notification-content
        // path; the policy exists to keep codec conversion (not ordinary
        // system-sound staging) off the main actor.
        await stageSystemSound(
            value: value,
            sourceDirectory: sourceDirectory,
            stagingDirectory: stagingDirectory
        )
    }

    static func stagedCustomSoundFileExtension(forSourceExtension sourceExtension: String) -> String {
        stagedFileExtension(forSourceExtension: sourceExtension)
    }

    static func stagedCustomSoundFileName(
        forSourceURL sourceURL: URL,
        destinationExtension: String
    ) -> String {
        stagedFileName(
            forSourceURL: sourceURL,
            destinationExtension: destinationExtension
        )
    }

    static func stagedCustomSoundURL(
        named fileName: String,
        stagingDirectory: URL? = nil
    ) -> URL {
        stagedURL(
            named: fileName,
            stagingDirectory: stagingDirectory
        )
    }

    @MainActor
    private static func playPreparedSound(_ prepared: PreparedNotificationSound) -> Bool {
        switch prepared {
        case .systemDefault:
            NSSound.beep()
            return true
        case .silent:
            return false
        case .named(let fileName):
            return playSoundFile(at: stagedURL(named: fileName))
        }
    }

    @MainActor
    private static func playSoundFile(at url: URL) -> Bool {
        guard let sound = NSSound(contentsOf: url, byReference: false) else {
            notificationSoundLogger.error(
                "Notification sound failed to load from path: \(url.path, privacy: .private)"
            )
            return false
        }
        retainActivePlaybackSound(sound)
        sound.delegate = activePlaybackSoundDelegate
        let didPlay = sound.play()
        if !didPlay {
            releaseActivePlaybackSound(sound)
        }
        return didPlay
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

    static func runCustomCommand(
        title: String,
        subtitle: String,
        body: String,
        defaults: UserDefaults = .standard
    ) {
        let command = (defaults.string(forKey: customCommandKey) ?? defaultCustomCommand)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        // Reuse the existing short-lived sound-state lock for command
        // admission. It is held only while incrementing a bounded counter;
        // shell execution remains on the utility queue outside the lock.
        activePlaybackSoundsLock.lock()
        let admitted = activeCustomCommandCount < maximumCustomCommandProcesses
        if admitted { activeCustomCommandCount += 1 }
        activePlaybackSoundsLock.unlock()
        guard admitted else {
            notificationSoundLogger.error(
                "Notification command dropped after reaching the in-flight limit"
            )
            return
        }
        customCommandQueue.async {
            let runner = NotificationSoundProcessRunner(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                timeoutNanoseconds: maximumCustomCommandTimeoutNanoseconds,
                capturesErrorOutput: false
            )
            var commandEnvironment = ProcessInfo.processInfo.environment
            commandEnvironment["CMUX_NOTIFICATION_TITLE"] = title
            commandEnvironment["CMUX_NOTIFICATION_SUBTITLE"] = subtitle
            commandEnvironment["CMUX_NOTIFICATION_BODY"] = body
            let environment = commandEnvironment
            Task.detached(priority: .utility) {
                defer { releaseCustomCommandAdmission() }
                do {
                    _ = try await runner.run(
                        arguments: ["-c", command],
                        environment: environment
                    )
                } catch {
                    notificationSoundLogger.error(
                        "Notification command failed: \(String(describing: error), privacy: .private)"
                    )
                }
            }
        }
    }

    private static func releaseCustomCommandAdmission() {
        activePlaybackSoundsLock.lock()
        activeCustomCommandCount = max(0, activeCustomCommandCount - 1)
        activePlaybackSoundsLock.unlock()
    }
}
