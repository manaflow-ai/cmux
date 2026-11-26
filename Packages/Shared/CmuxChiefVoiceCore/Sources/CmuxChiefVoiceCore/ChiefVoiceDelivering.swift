import Foundation

/// Sends a finished voice note to the user's Chief conversation.
///
/// The iOS adapter prepares the audio as a Home attachment and sends it with the
/// transcript as the message text through `HomeStore`.
public protocol ChiefVoiceDelivering: Sendable {
    /// Delivers `note` with its audio file at `audioURL`.
    /// - Throws: When there is no reachable Chief conversation or the send fails;
    ///   the note then stays in the outbox.
    func deliver(_ note: VoiceNote, audioURL: URL) async throws
}
