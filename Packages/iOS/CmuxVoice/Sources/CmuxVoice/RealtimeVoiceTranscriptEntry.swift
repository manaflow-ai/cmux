public import Foundation

/// One finalized user or assistant turn shown in the Voice Mode transcript.
public struct RealtimeVoiceTranscriptEntry: Identifiable, Equatable, Sendable {
    /// Stable identity for SwiftUI rendering.
    public let id: UUID
    /// Turn speaker.
    public let role: RealtimeVoiceTranscriptRole
    /// Final transcript text.
    public let text: String

    /// Creates a finalized transcript entry.
    /// - Parameters:
    ///   - id: Stable entry identity.
    ///   - role: Turn speaker.
    ///   - text: Final transcript text.
    public init(
        id: UUID = UUID(),
        role: RealtimeVoiceTranscriptRole,
        text: String
    ) {
        self.id = id
        self.role = role
        self.text = text
    }
}
