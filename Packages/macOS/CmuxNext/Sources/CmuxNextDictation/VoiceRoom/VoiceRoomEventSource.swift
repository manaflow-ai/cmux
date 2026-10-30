/// The room's pause state as it changes: anyone in the room can pause recording for everyone.
public protocol VoiceRoomEventSource: Sendable {
    /// Each time the room's pause state is known or changes: true while paused. Ends when the
    /// connection ends.
    func pauses() -> AsyncStream<Bool>
}
