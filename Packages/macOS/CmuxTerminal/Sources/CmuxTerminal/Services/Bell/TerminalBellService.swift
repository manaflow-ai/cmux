internal import AppKit

/// Presents terminal bells through audio-only effects that cannot activate cmux.
///
/// Application and window attention are intentionally absent from this API.
/// Background activity is represented by cmux-owned pane, workspace, and Dock
/// state instead of AppKit process-level attention, which can promote an
/// entire Stage Manager window set.
@MainActor
public final class TerminalBellService {
    private let systemBeep: () -> Void
    private let soundLoader: (String) -> NSSound?
    private var activeSound: NSSound?

    /// Creates a terminal bell service backed by AppKit audio playback.
    public convenience init() {
        self.init(
            systemBeep: { NSSound.beep() },
            soundLoader: { NSSound(contentsOfFile: $0, byReference: false) }
        )
    }

    init(
        systemBeep: @escaping () -> Void,
        soundLoader: @escaping (String) -> NSSound?
    ) {
        self.systemBeep = systemBeep
        self.soundLoader = soundLoader
    }

    /// Plays the audio effects in a terminal bell presentation.
    ///
    /// Visual attention remains the terminal host's responsibility because it
    /// must resolve the exact pane, workspace, or Dock owner.
    ///
    /// - Parameter presentation: The value-selected audio and visual effects.
    public func ring(presentation: TerminalBellPresentation) {
        if presentation.systemSoundEnabled {
            systemBeep()
        }

        guard let customAudioPath = presentation.customAudioPath,
              let sound = soundLoader(customAudioPath) else {
            return
        }
        sound.volume = presentation.customAudioVolume
        activeSound = sound
        if !sound.play() {
            activeSound = nil
        }
    }
}
