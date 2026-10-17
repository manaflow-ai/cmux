/// An actionable permission request from the agent, awaiting a decision.
///
/// Synthesized by the host from agent hook events (transcripts do not carry
/// permission prompts). Once answered, the host republishes the message with
/// ``resolution`` set; renderers then freeze the card into a receipt.
public struct ChatPermissionRequest: Sendable, Equatable, Codable {
    /// How the request was answered.
    public enum Resolution: String, Sendable, Equatable, Codable {
        /// The user approved the request.
        case approved
        /// The user denied the request.
        case denied
        /// The request lapsed (agent stopped or session ended unanswered).
        case expired
    }

    /// Short title for the card (e.g. "Claude wants to run:").
    public let title: String

    /// The command or tool being gated, rendered as text.
    public let subject: String

    /// The decision, or `nil` while the request is pending.
    public let resolution: Resolution?
    public let requestID: String?

    /// Creates a permission request.
    ///
    /// - Parameters:
    ///   - title: Short card title.
    ///   - subject: The gated command or tool, as text.
    ///   - resolution: The decision, or `nil` while pending.
    public init(title: String, subject: String, resolution: Resolution? = nil, requestID: String? = nil) {
        self.title = title
        self.subject = subject
        self.resolution = resolution
        self.requestID = requestID
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case subject
        case resolution
        case requestID = "request_id"
    }
}
