/// The presentation selected for one terminal bell event.
///
/// Audio stays process-local, while visual attention is routed by the terminal
/// host into cmux-owned pane, workspace, or Dock unread state. Process-level
/// application attention is deliberately not representable.
public struct TerminalBellPresentation: Equatable, Sendable {
    /// Whether to play the macOS system alert sound.
    public let systemSoundEnabled: Bool

    /// The custom sound path, or `nil` when custom audio is disabled.
    public let customAudioPath: String?

    /// The custom sound volume, clamped to the `0...1` range.
    public let customAudioVolume: Float

    /// Whether the owning terminal should surface visual unread attention.
    public let visualBellEnabled: Bool

    /// Creates a terminal bell presentation with no process-activation option.
    ///
    /// - Parameters:
    ///   - systemSoundEnabled: Whether to play the macOS system alert sound.
    ///   - customAudioPath: The custom sound path, or `nil` to disable it.
    ///   - customAudioVolume: The custom sound volume, clamped to `0...1`.
    ///   - visualBellEnabled: Whether to route visual attention through the
    ///     owning cmux surface.
    public init(
        systemSoundEnabled: Bool,
        customAudioPath: String?,
        customAudioVolume: Float,
        visualBellEnabled: Bool
    ) {
        self.systemSoundEnabled = systemSoundEnabled
        self.customAudioPath = customAudioPath
        self.customAudioVolume = min(1, max(0, customAudioVolume))
        self.visualBellEnabled = visualBellEnabled
    }
}
