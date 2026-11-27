import Foundation

/// Delivers a voice note to a Chief that takes text messages only.
///
/// The cmux-next-ios Chief conversation (`ChiefSession.send`) carries text and
/// images, not audio. This adapter sends the on-device transcript as the
/// message text, or a short fallback line built from the note's duration when
/// there is no transcript. The audio stays on the phone until delivery
/// succeeds; then the ``ChiefCallCoordinator`` removes it with the note.
///
/// ```swift
/// let delivery = ChiefVoiceTextDelivery(
///     send: { text in ChiefSources.shared.primary.send(ConversationComposeMessage(text: text)) },
///     noTranscript: { seconds in String(localized: "Voice note (\(Int(seconds)) s), no transcript") }
/// )
/// ```
public struct ChiefVoiceTextDelivery: ChiefVoiceDelivering {
    private let send: @MainActor @Sendable (String) async throws -> Void
    private let noTranscript: @Sendable (TimeInterval) -> String

    /// Creates the delivery.
    /// - Parameters:
    ///   - send: Sends one text message to the Chief conversation; throws when no Chief is reachable,
    ///     which keeps the note in the outbox.
    ///   - noTranscript: The message text for a note without a transcript, given its length in seconds.
    public init(send: @escaping @MainActor @Sendable (String) async throws -> Void,
                noTranscript: @escaping @Sendable (TimeInterval) -> String) {
        self.send = send
        self.noTranscript = noTranscript
    }

    /// Sends the transcript of `note`, or the fallback line.
    /// - Parameters:
    ///   - note: The finished note.
    ///   - audioURL: The note's audio; not sent, since the Chief takes text only.
    /// - Throws: What `send` throws.
    public func deliver(_ note: VoiceNote, audioURL: URL) async throws {
        let transcript = note.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try await send(transcript.isEmpty ? noTranscript(note.duration) : transcript)
    }
}
