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
    /// How long a sound plays, in seconds (nil: its whole file); the App's composition root sets it
    /// from `notifications.sounds` (``NotificationSoundPreferences/length(for:)``). The default player
    /// reads it.
    public var length: @MainActor (String) -> Double? = { _ in nil }

    /// - Parameters:
    ///   - player: The sound output; nil makes an `NSSound` player that stops each sound at ``length``.
    ///   - now: The cooldown's clock.
    public init(player: (any NotificationSoundPlaying)? = nil,
                now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.now = now
        if let player {
            self.player = player
        } else {
            let own = NotificationSoundPlayer()
            self.player = own
            own.length = { [weak self] in self?.length($0) }
        }
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
