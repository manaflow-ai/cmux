import AppKit

/// ``NotificationSoundPlaying`` with `NSSound`: one instance per sound, kept, so a burst never
/// loads a file twice and a sound still playing restarts instead of stacking.
///
/// Every sound plays through the app's own audio (cmux#55600): never through notification
/// permission. `"default"` is the Mac's alert sound (Sound settings), played here unless a banner
/// that macOS sounds carries it (``bannersCarrySound``); a denied, not yet allowed or
/// sound-off banner carries nothing, so the app plays it.
@MainActor
public final class NotificationSoundPlayer: NotificationSoundPlaying {
    private var sounds: [String: NSSound] = [:]
    /// Whether a banner shown now plays its own `"default"` sound (the app's notification permission);
    /// the app sets it, and it reads true until then.
    public var bannersCarrySound: @MainActor () -> Bool
    /// Where a loaded sound goes: `NSSound.play()`; tests record instead.
    public var output: @MainActor (NSSound) -> Void

    /// A player with no sound loaded yet.
    public init(bannersCarrySound: @escaping @MainActor () -> Bool = { true },
                output: @escaping @MainActor (NSSound) -> Void = { $0.play() }) {
        self.bannersCarrySound = bannersCarrySound
        self.output = output
    }

    public func play(_ name: String, volume: Double, banner: Bool) {
        guard name != "none", !name.isEmpty else { return }
        if name == "default", banner, bannersCarrySound() { return }
        // A Sound settings choice that no longer loads falls back to Tink.
        let resolved = name == "default" ? sound(named: Self.alertSoundName()) ?? sound(named: Self.fallbackAlertSound) : sound(named: name)
        guard let sound = resolved else { return }
        sound.stop()
        sound.volume = Float(min(max(volume, 0), 1))
        output(sound)
    }

    /// The Mac's alert sound, which a `"default"` banner plays: Sound settings' choice (an absolute
    /// path in the global `com.apple.sound.beep.sound`; one that no longer loads plays Tink), else Tink.
    public static func alertSoundName(_ global: [String: Any]? = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)) -> String {
        if let path = global?["com.apple.sound.beep.sound"] as? String, path.hasPrefix("/") {
            return path
        }
        return fallbackAlertSound
    }

    /// The alert sound when Sound settings never chose one (`/System/Library/Sounds/Tink.aiff`).
    public static let fallbackAlertSound = "Tink"

    private func sound(named name: String) -> NSSound? {
        if let sound = sounds[name] { return sound }
        let path = (name as NSString).expandingTildeInPath
        // A path loads by reference (NSSound reads the file when it plays); a name is the system's
        // cached lookup, copied so this instance's volume never changes another player's.
        let sound = path.hasPrefix("/") ? NSSound(contentsOfFile: path, byReference: true) : NSSound(named: NSSound.Name(name))?.copy() as? NSSound
        if let sound { sounds[name] = sound }
        return sound
    }
}
