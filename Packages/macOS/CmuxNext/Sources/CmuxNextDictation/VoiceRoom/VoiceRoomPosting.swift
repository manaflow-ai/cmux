/// Sends this Mac's lines to the room.
public protocol VoiceRoomPosting: Sendable {
    /// Sends one line.
    ///
    /// - Parameter line: The line.
    /// - Returns: True when the room is paused (it dropped the line); the session stops listening.
    /// - Throws: ``VoiceRoomError`` when the room could not take it.
    func post(_ line: VoiceRoomLine) async throws -> Bool
}

/// Why the room did not take a line.
public enum VoiceRoomError: Error, Equatable, Sendable {
    /// The room answered with this HTTP status.
    case status(Int)
    /// The room's answer was not the expected JSON.
    case badReply
}
