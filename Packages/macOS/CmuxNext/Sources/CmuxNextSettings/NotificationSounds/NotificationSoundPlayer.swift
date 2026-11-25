import AppKit
public import CmuxNextWakeups
public import Foundation

/// ``NotificationSoundPlaying`` with `NSSound`: one instance per sound, kept, so a burst never
/// loads a file twice and a sound still playing restarts instead of stacking. A sound longer than
/// `notifications.sounds.maxSeconds` stops at it (a ``DemandTimer`` per sound, so a replay
/// pushes its own stop back and never cuts another sound short).
///
/// Notification sounds follow the person's notification permission (cmux#55600): nothing plays,
/// previews included, until macOS allows cmux notifications with sound (``soundsAllowed``). Then
/// `"default"` rides its banner, and plays here as the Mac's alert sound (Sound settings) when no
/// banner carries it (a preview, a decision that posts none).
@MainActor
public final class NotificationSoundPlayer: NotificationSoundPlaying {
    /// Loads a sound by name, or from `file` when the library keeps it (``NotificationSoundLibrary/customFiles()``).
    public typealias Loader = @MainActor (_ name: String, _ file: URL?) -> (any NotificationSoundOutput)?

    private var sounds: [String: any NotificationSoundOutput] = [:]
    private var stops: [String: DemandTimer] = [:]
    private var files: [String: URL] = [:]
    private var maxSeconds: Double = 0
    private let clock: any Clock<Duration>
    private let load: Loader
    /// Whether macOS allows cmux notifications with sound now (the app's notification permission);
    /// the app sets it, and it reads true until then.
    public var soundsAllowed: @MainActor () -> Bool = { true }

    /// - Parameters:
    ///   - clock: The stop deadlines' clock; tests pass their own.
    ///   - load: Makes a sound; `NSSound` by default.
    public init(clock: any Clock<Duration> = ContinuousClock(), load: @escaping Loader = NotificationSoundPlayer.nsSound) {
        self.clock = clock
        self.load = load
    }

    public func play(_ name: String, volume: Double, banner: Bool) {
        guard name != "none", !name.isEmpty else { return }
        guard soundsAllowed() else { return }
        if name == "default", banner { return } // the banner plays it
        var key = name
        if name == "default" { // Sound settings' alert sound; a choice that no longer loads falls back to Tink
            key = Self.alertSoundName()
            if sound(named: key) == nil { key = Self.fallbackAlertSound }
        }
        guard let sound = sound(named: key) else { return }
        sound.stop()
        sound.volume = Float(min(max(volume, 0), 1))
        sound.play()
        guard maxSeconds > 0 else {
            stops[key]?.cancel()
            return
        }
        let timer = stops[key] ?? DemandTimer(owner: "notification-sound-length", clock: clock)
        stops[key] = timer
        timer.schedule(after: .milliseconds(Int((maxSeconds * 1_000).rounded()))) { @MainActor [weak self] in
            self?.sounds[key]?.stop()
        }
    }

    public func use(files: [String: URL], maxSeconds: Double) {
        if files != self.files {
            // A file replaced under the same name loads again.
            for name in Set(self.files.keys).union(files.keys) where self.files[name] != files[name] { sounds[name] = nil }
            self.files = files
        }
        self.maxSeconds = max(maxSeconds, 0)
    }

    /// The Mac's alert sound, which a `"default"` banner plays: Sound settings' choice (an absolute
    /// path in the global `com.apple.sound.beep.sound`), else Tink.
    public static func alertSoundName(_ global: [String: Any]? = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)) -> String {
        if let path = global?["com.apple.sound.beep.sound"] as? String, path.hasPrefix("/") {
            return path
        }
        return fallbackAlertSound
    }

    /// The alert sound when Sound settings never chose one (`/System/Library/Sounds/Tink.aiff`).
    public static let fallbackAlertSound = "Tink"

    private func sound(named name: String) -> (any NotificationSoundOutput)? {
        if let sound = sounds[name] { return sound }
        let sound = load(name, files[name])
        if let sound { sounds[name] = sound }
        return sound
    }

    /// The app's loader: a kept file or a path by reference (NSSound reads the file when it plays);
    /// a name is the system's cached lookup, copied so this instance's volume never changes another
    /// player's.
    public static func nsSound(_ name: String, _ file: URL?) -> (any NotificationSoundOutput)? {
        if let file { return NSSound(contentsOf: file, byReference: true) }
        let path = (name as NSString).expandingTildeInPath
        return path.hasPrefix("/") ? NSSound(contentsOfFile: path, byReference: true) : NSSound(named: NSSound.Name(name))?.copy() as? NSSound
    }
}

/// What ``NotificationSoundPlayer`` drives (on the main actor): `NSSound` in the app, a recorder in tests.
public protocol NotificationSoundOutput: AnyObject {
    var volume: Float { get set }
    @discardableResult func play() -> Bool
    @discardableResult func stop() -> Bool
}

extension NSSound: NotificationSoundOutput {}
