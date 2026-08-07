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

    /// Plays the audio effects enabled for a terminal bell.
    ///
    /// - Parameters:
    ///   - systemSoundEnabled: Whether to play the macOS system alert sound.
    ///   - customAudioPath: The custom sound path, or `nil` when custom audio
    ///     is disabled or has no configured file.
    ///   - customAudioVolume: The pre-clamped playback volume for custom audio.
    public func ring(
        systemSoundEnabled: Bool,
        customAudioPath: String?,
        customAudioVolume: Float
    ) {
        if systemSoundEnabled {
            systemBeep()
        }

        guard let customAudioPath,
              let sound = soundLoader(customAudioPath) else {
            return
        }
        sound.volume = customAudioVolume
        activeSound = sound
        if !sound.play() {
            activeSound = nil
        }
    }
}
