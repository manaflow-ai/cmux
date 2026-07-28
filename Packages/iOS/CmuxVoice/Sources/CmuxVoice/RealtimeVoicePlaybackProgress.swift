/// Played portion of one assistant audio item when the user interrupts it.
public struct RealtimeVoicePlaybackProgress: Equatable, Sendable {
    /// Realtime conversation item containing the interrupted audio.
    public let itemID: String
    /// Approximate audio duration fully played on the device.
    public let audioEndMilliseconds: Int

    /// Creates interruption progress.
    /// - Parameters:
    ///   - itemID: Realtime conversation item identifier.
    ///   - audioEndMilliseconds: Fully played duration in milliseconds.
    public init(itemID: String, audioEndMilliseconds: Int) {
        self.itemID = itemID
        self.audioEndMilliseconds = audioEndMilliseconds
    }
}
