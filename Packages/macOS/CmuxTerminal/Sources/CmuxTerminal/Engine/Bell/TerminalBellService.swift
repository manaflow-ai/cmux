internal import AppKit

/// Plays the terminal bell using the resolved Ghostty `bell-features` flags.
///
/// Replaces the `ringBell()` body and the `bellAudioSound` retain slot that
/// lived on the `GhosttyApp` god type. The flag/path/volume reads stay with the
/// caller because they decode a live `ghostty_config_t` handle; this service
/// owns only the AppKit side effects (system beep, audio file playback,
/// dock-attention request) and the `NSSound` strong reference that keeps an
/// asynchronously playing sound alive.
///
/// Isolation design: `NSSound.play()`, `NSSound.beep()`, and
/// `NSApp.requestUserAttention(_:)` are main-thread AppKit APIs. The legacy
/// `GhosttyApp` was a non-isolated, non-`Sendable` class whose bell state was
/// touched only from the main thread by convention (the OSC/runtime bell
/// callback marshals to main via `performOnMain`). This lift preserves that
/// exact isolation: the service is a plain non-isolated, non-`Sendable` class,
/// so it stores `NSSound?` without isolation friction and never crosses an
/// actor boundary, matching the original byte-for-byte.
public final class TerminalBellService {
    /// Keeps the most recent asynchronously-playing bell sound alive until it
    /// finishes or is superseded, matching the legacy `bellAudioSound` slot.
    private var audioSound: NSSound?

    /// Creates a bell service with no sound playing.
    public init() {}

    /// Rings the bell according to `features` (the Ghostty `bell-features`
    /// bitmask): bit 0 = system beep, bit 1 = play the audio file at
    /// `audioPath` at `audioVolume`, bit 2 = request dock user attention.
    public func ring(features: CUnsignedInt, audioPath: String?, audioVolume: Float) {
        if (features & (1 << 0)) != 0 {
            NSSound.beep()
        }

        if (features & (1 << 1)) != 0,
           let path = audioPath,
           let sound = NSSound(contentsOfFile: path, byReference: false) {
            sound.volume = audioVolume
            audioSound = sound
            if !sound.play() {
                audioSound = nil
            }
        }

        if (features & (1 << 2)) != 0 {
            // `NSApp` and `requestUserAttention(_:)` are `@MainActor`-isolated.
            // `ring(...)` is main-thread-confined by contract (the OSC/runtime
            // bell callback marshals to main before calling this), and the type
            // deliberately stays non-isolated to avoid rippling `@MainActor` onto
            // the non-isolated engine/NSView readers that own it. Assert the
            // main-actor isolation that already holds rather than widening it.
            MainActor.assumeIsolated {
                NSApp.requestUserAttention(.informationalRequest)
            }
        }
    }
}
