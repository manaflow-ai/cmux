import AppKit
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
    private static let systemSoundDirectoryURL = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
    private static let soundPlayer = NotificationSoundPlayer()
    private static let dndAssertionQueue = DispatchQueue(
        label: "com.cmuxterm.notification-dnd-assertion",
        qos: .utility
    )
    // Owns the custom/system sound file-staging engine (copy/transcode into
    // ~/Library/Sounds, metadata sidecars, stale cleanup, background dedup).
    // A single instance backs the whole process so the in-flight dedup set is
    // shared, mirroring `soundPlayer`/`customCommandRunner`.
    private static let customSoundStagingService = CustomSoundStagingService()

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
        return customSoundStagingService.stagedCustomSoundName(rawPath: rawPath)
    }

    static func prepareCustomFileForNotifications(path: String) -> Result<String, CustomSoundPreparationIssue> {
        customSoundStagingService.prepareCustomFile(path: path)
    }

    static func customFileURL(defaults: UserDefaults = .standard) -> URL? {
        guard let path = normalizedCustomFilePath(defaults.string(forKey: customFilePathKey) ?? defaultCustomFilePath) else {
            return nil
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static func playCustomFileSound(defaults: UserDefaults = .standard) {
        guard let url = customFileURL(defaults: defaults) else { return }
        soundPlayer.playFile(at: url)
    }

    static func playCustomFileSound(path: String) {
        guard let normalizedPath = normalizedCustomFilePath(path) else { return }
        let url = URL(fileURLWithPath: (normalizedPath as NSString).expandingTildeInPath)
        soundPlayer.playFile(at: url)
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
        assertionsFileURL: URL = FocusAssertionStore.defaultAssertionsFileURL,
        completion: ((_ didPlay: Bool) -> Void)? = nil
    ) {
        dndAssertionQueue.async {
            let suppressed = FocusAssertionStore(assertionsFileURL: assertionsFileURL).isSuppressedByActiveFocus
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
            soundPlayer.playSystem(named: value)
        }
    }

    static func stagedSystemSoundFileName(for value: String) -> String {
        customSoundStagingService.stagedSystemSoundFileName(for: value)
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
        return customSoundStagingService.stageSystemSound(
            for: value,
            fileManager: fileManager,
            sourceDirectory: sourceDirectory,
            stagingDirectory: stagingDirectory
        )
    }

    static func stagedCustomSoundFileExtension(forSourceExtension sourceExtension: String) -> String {
        customSoundStagingService.stagedCustomSoundFileExtension(forSourceExtension: sourceExtension)
    }

    static func stagedCustomSoundFileName(forSourceURL sourceURL: URL, destinationExtension: String) -> String {
        customSoundStagingService.stagedCustomSoundFileName(
            forSourceURL: sourceURL,
            destinationExtension: destinationExtension
        )
    }

    private static func normalizedCustomFilePath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // Shared composition-point instance: one runner backs the whole process so
    // custom commands serialize on the runner's single queue.
    private static let customCommandRunner = NotificationCustomCommandRunner()

    static func runCustomCommand(title: String, subtitle: String, body: String, defaults: UserDefaults = .standard) {
        customCommandRunner.run(title: title, subtitle: subtitle, body: body, defaults: defaults)
    }
}
