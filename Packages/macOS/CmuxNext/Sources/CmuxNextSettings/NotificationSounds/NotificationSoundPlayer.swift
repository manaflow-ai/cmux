import AppKit
import CmuxNextWakeups

/// ``NotificationSoundPlaying`` with `NSSound`: one instance per sound, kept, so a burst never
/// loads a file twice and a sound still playing restarts instead of stacking. A sound longer than
/// its length (``length``, `notifications.sounds.maxSeconds` and `.lengths`) stops at that length.
@MainActor
public final class NotificationSoundPlayer: NotificationSoundPlaying {
    private var sounds: [String: NSSound] = [:]
    /// One stop deadline per sound name, replaced when that sound starts again.
    private var stops: [String: DemandTimer] = [:]
    /// Each sound's play count, so a stop meant for an earlier play never cuts a newer one short.
    private var plays: [String: UInt64] = [:]
    private let clock: any Clock<Duration>
    /// How long a sound plays, in seconds; nil plays its file to its end. The gate reads the
    /// person's `notifications.sounds` (``NotificationSoundPreferences/length(for:)``).
    public var length: @MainActor (String) -> Double? = { _ in nil }

    /// A player with no sound loaded yet.
    ///
    /// - Parameter clock: The clock the stop deadlines run on; tests pass their own.
    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    public func play(_ name: String, volume: Double, banner: Bool) {
        guard name != "none", !name.isEmpty else { return }
        guard name != "default" else {
            if !banner { NSSound.beep() }
            return
        }
        guard let sound = sound(named: name) else { return }
        sound.stop()
        sound.volume = Float(min(max(volume, 0), 1))
        sound.play()
        let play = (plays[name] ?? 0) &+ 1
        plays[name] = play
        guard let stop = Self.stopAfter(length: length(name), duration: sound.duration) else {
            stops[name]?.cancel()
            return
        }
        let timer = stops[name] ?? DemandTimer(owner: "notifications.soundLength", clock: clock)
        stops[name] = timer
        // The deadline is claimed off the main actor before it hops here, so a replay in between
        // must not be stopped by the earlier play's deadline.
        timer.schedule(after: stop) { @MainActor [weak self] in
            guard let self, self.plays[name] == play else { return }
            self.sounds[name]?.stop()
        }
    }

    /// When to stop a sound of `duration` seconds that plays for `length` seconds: nil when it ends
    /// on its own first (no length, or a file no longer than it).
    public nonisolated static func stopAfter(length: Double?, duration: Double) -> Duration? {
        guard let length, length > 0, duration > length else { return nil }
        return .milliseconds(Int((length * 1_000).rounded()))
    }

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
