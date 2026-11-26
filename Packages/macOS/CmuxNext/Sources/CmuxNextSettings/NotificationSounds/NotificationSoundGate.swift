public import CmuxNextWakeups
public import Foundation

/// Where every notification sound passes on its way out: the burst cooldown
/// (``NotificationSoundThrottle``, `notifications.sounds.cooldownSeconds`), then the player. The
/// notification service holds one; tests pass a recorder and their own clock.
///
/// ```swift
/// let gate = NotificationSoundGate(player: recorder, now: { clock.now })
/// gate.play(decision, cooldownSeconds: 1.5, banner: false)
/// ```
@MainActor
public final class NotificationSoundGate {
    /// Plays what passes the cooldown.
    public let player: any NotificationSoundPlaying
    private var throttle = NotificationSoundThrottle(cooldown: .zero)
    private let now: @MainActor () -> ContinuousClock.Instant
    /// A workspace's groups by its id, innermost first, for its sound rules; the App's composition root
    /// sets it (the person's sidebar groups live there).
    public var groups: @MainActor (String) -> [NotificationSoundScope.Group] = { _ in [] }
    /// Where sounds are listed and where Custom Sound… copies a file.
    public let library: NotificationSoundLibrary
    /// Every installed sound name (``NotificationSoundLibrary/names()``), after the first
    /// ``refreshSounds(work:)``: the Settings page's menu and the palette's list.
    public private(set) var soundNames: [String] = []
    private var customFiles: [String: URL] = [:]
    /// The newest ``refreshSounds(work:)``: an older listing that finishes after it is dropped.
    private var listings: UInt64 = 0
    private var maxSeconds: Double = NotificationSoundPreferences.maxSecondsDefault

    /// - Parameters:
    ///   - player: The sound output (`NSSound` by default).
    ///   - library: The sound folders; tests pass temporary ones.
    ///   - now: The cooldown's clock.
    public init(player: any NotificationSoundPlaying = NotificationSoundPlayer(),
                library: NotificationSoundLibrary = NotificationSoundLibrary(),
                now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.player = player
        self.library = library
        self.now = now
    }

    /// The master volume a Settings preview plays at (`notifications.sounds.volume`).
    public private(set) var volume: Double = NotificationSoundPreferences.volumeDefault

    /// Applies the sound preferences the player and previews follow (`notifications.sounds.volume`
    /// and `maxSeconds`).
    public func apply(_ sounds: NotificationSoundPreferences) {
        volume = sounds.volume
        guard sounds.maxSeconds != maxSeconds else { return }
        maxSeconds = sounds.maxSeconds
        player.use(files: customFiles, maxSeconds: maxSeconds)
    }

    /// Lists the installed sounds and the files cmux keeps off the main thread, then hands the files
    /// to the player. Call at launch and after an import.
    public func refreshSounds(work: BackgroundWork) async {
        let library = library
        listings &+= 1
        let listing = listings
        guard let listed = try? await work.run(.bestEffort, mayBlock: .files, { (library.names(), library.customFiles()) }),
              listing == listings else { return } // a later listing (an import's) is newer
        take(names: listed.0, files: listed.1)
    }

    /// Takes a listing of ``library`` (``refreshSounds(work:)`` makes one off the main thread).
    public func take(names: [String], files: [String: URL]) {
        soundNames = names
        customFiles = files
        player.use(files: customFiles, maxSeconds: maxSeconds)
    }

    /// Clears `decision`'s sound when the cooldown holds it: an event no more urgent than the last
    /// one that sounded, within `cooldownSeconds` of it. A banner posted for `decision` then rides
    /// silent too.
    ///
    /// - Returns: False when the sound was held.
    @discardableResult
    public func admit(_ decision: inout NotificationPolicy.Decision, cooldownSeconds: Double) -> Bool {
        guard decision.sound != nil else { return true }
        throttle.cooldown = .milliseconds(Int((max(cooldownSeconds, 0) * 1_000).rounded()))
        guard throttle.admit(decision.soundEvent, at: now()) else {
            decision.sound = nil
            return false
        }
        return true
    }

    /// Plays `decision`'s sound itself (no banner carries it to the person), after the cooldown.
    ///
    /// - Parameters:
    ///   - decision: The arrival's decision; nothing plays without a sound.
    ///   - cooldownSeconds: `notifications.sounds.cooldownSeconds`.
    ///   - banner: A banner shows with it (``NotificationSoundPlaying/play(_:volume:banner:)``).
    public func play(_ decision: NotificationPolicy.Decision, cooldownSeconds: Double, banner: Bool) {
        var decision = decision
        guard admit(&decision, cooldownSeconds: cooldownSeconds), let sound = decision.sound else { return }
        player.play(sound, volume: decision.soundVolume, banner: banner)
    }

    /// Plays `name` at `volume` now, past the cooldown: a preview the person asked for.
    public func preview(_ name: String, volume: Double) {
        player.play(name, volume: volume, banner: false)
    }
}
