import AppKit
public import Foundation

/// Plays notification sounds through `NSSound` and keeps each playing sound
/// alive until it finishes.
///
/// `NSSound.play()` is fire-and-forget: the framework does not retain the
/// `NSSound` for the duration of playback, and `NSSound.delegate` is a weak
/// reference. Without an owner the sound would deallocate mid-playback and go
/// silent. This player therefore retains every started sound in a dictionary
/// keyed by `ObjectIdentifier`, sets itself (via a shared delegate) as the
/// sound's delegate, and drops the retain when `sound(_:didFinishPlaying:)`
/// fires (or immediately when `play()` returns `false`).
///
/// The retain dictionary is guarded by an `NSLock` rather than an actor on
/// purpose: `NSSoundDelegate.sound(_:didFinishPlaying:)` is a synchronous
/// AppKit callback that cannot `await`, so it must release the retain
/// synchronously, and the lock guards a tiny value read by that synchronous
/// callback. The type stays non-`@MainActor` to preserve the legacy
/// off-main-safe contract and the `DispatchQueue.main.async` hop in
/// ``playFile(at:)`` (the file path defers the load + play to the next main
/// run-loop tick). Lifted byte-identically from the former
/// `NotificationSoundSettings` static sound-playback members.
public final class NotificationSoundPlayer: @unchecked Sendable {
    // `activePlaybackSounds` is guarded by `activePlaybackSoundsLock`;
    // `activePlaybackSoundDelegate` is an immutable `let` set once in `init`.
    private let activePlaybackSoundsLock = NSLock()
    private var activePlaybackSounds: [ObjectIdentifier: NSSound] = [:]
    private let activePlaybackSoundDelegate: ActivePlaybackSoundDelegate

    /// Creates a player. A single instance must back every notification sound
    /// so all in-flight sounds share one retain table and one delegate.
    public init() {
        activePlaybackSoundDelegate = ActivePlaybackSoundDelegate()
        activePlaybackSoundDelegate.player = self
    }

    /// Plays the named macOS system sound (e.g. `Glass`, `Ping`), retaining it
    /// for the duration of playback. A name `NSSound` cannot resolve is a no-op.
    public func playSystem(named value: String) {
        guard let sound = NSSound(named: NSSound.Name(value)) else {
            return
        }
        retainActivePlaybackSound(sound)
        sound.delegate = activePlaybackSoundDelegate
        if !sound.play() {
            releaseActivePlaybackSound(sound)
        }
    }

    /// Plays the sound file at `url` on the main run loop, retaining it for the
    /// duration of playback. A file `NSSound` cannot load is logged and ignored.
    public func playFile(at url: URL) {
        DispatchQueue.main.async { [self] in
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

    fileprivate func retainActivePlaybackSound(_ sound: NSSound) {
        activePlaybackSoundsLock.lock()
        activePlaybackSounds[ObjectIdentifier(sound)] = sound
        activePlaybackSoundsLock.unlock()
    }

    fileprivate func releaseActivePlaybackSound(_ sound: NSSound) {
        activePlaybackSoundsLock.lock()
        activePlaybackSounds.removeValue(forKey: ObjectIdentifier(sound))
        activePlaybackSoundsLock.unlock()
    }
}

/// Forwards `NSSound` playback-finished callbacks back to the owning
/// ``NotificationSoundPlayer`` so it can drop the sound's retain. Held by the
/// player (a strong `let`); references the player weakly to avoid a cycle.
private final class ActivePlaybackSoundDelegate: NSObject, NSSoundDelegate {
    weak var player: NotificationSoundPlayer?

    func sound(_ sound: NSSound, didFinishPlaying finishedPlaying: Bool) {
        player?.releaseActivePlaybackSound(sound)
    }
}
