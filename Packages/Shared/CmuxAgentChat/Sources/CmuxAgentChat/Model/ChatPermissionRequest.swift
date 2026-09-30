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

    /// One decision offered by the backend. The index is stable for the
    /// lifetime of the request and is sent through the provider-neutral
    /// answer API.
    public struct Option: Sendable, Equatable, Codable, Identifiable {
        /// Zero-based display and answer index.
        public let index: Int
        /// Human-readable action label.
        public let label: String

        public var id: Int { index }

        public init(index: Int, label: String) {
            self.index = index
            self.label = label
        }
    }

    /// Short title for the card (e.g. "Claude wants to run:").
    public let title: String

    /// The command or tool being gated, rendered as text.
    public let subject: String

    /// The decision, or `nil` while the request is pending.
    public let resolution: Resolution?

    /// Choices offered by the backend, in display order.
    public let options: [Option]

    /// Creates a permission request.
    ///
    /// - Parameters:
    ///   - title: Short card title.
    ///   - subject: The gated command or tool, as text.
    ///   - resolution: The decision, or `nil` while pending.
    ///   - options: Choices offered by the backend.
    public init(
        title: String,
        subject: String,
        resolution: Resolution? = nil,
        options: [Option] = []
    ) {
        self.title = title
        self.subject = subject
        self.resolution = resolution
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case subject
        case resolution
        case options
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        subject = try container.decode(String.self, forKey: .subject)
        resolution = try container.decodeIfPresent(Resolution.self, forKey: .resolution)
        // This field was added after the first wire version.
        options = try container.decodeIfPresent([Option].self, forKey: .options) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(subject, forKey: .subject)
        try container.encodeIfPresent(resolution, forKey: .resolution)
        if !options.isEmpty {
            try container.encode(options, forKey: .options)
        }
    }
}
