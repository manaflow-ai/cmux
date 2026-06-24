/// A single parsed turn in a RovoDev transcript preview: the normalized speaker
/// `role` (`user`/`assistant`/`system`/`tool`/`event`) and the joined `text`.
public struct RovoDevTranscriptPreviewTurn: Equatable, Sendable {
    public let role: String
    public let text: String

    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}
