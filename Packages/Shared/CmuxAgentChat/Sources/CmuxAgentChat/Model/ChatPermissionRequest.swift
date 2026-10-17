/// An actionable permission request from the agent, awaiting a decision.
///
/// Synthesized by the host from agent hook events (transcripts do not carry
/// permission prompts). Once answered, the host republishes the message with
/// ``resolution`` set; renderers then freeze the card into a receipt.
public struct ChatPermissionRequest: Sendable, Equatable, Codable {
    /// One explicit choice shown to the user. The host maps the stable display
    /// index back to the provider's permission mode.
    public struct Option: Sendable, Equatable, Codable, Identifiable {
        public var id: String { label }
        public let label: String
        public let detail: String?

        public init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }
    }

    /// How the request was answered.
    public enum Resolution: String, Sendable, Equatable, Codable {
        /// The user approved the request.
        case approved
        /// The user denied the request.
        case denied
        /// The request lapsed (agent stopped or session ended unanswered).
        case expired
        /// The user approved this request for future matching actions.
        case approvedAlways
        /// The user approved all matching actions for the current session.
        case approvedAll
    }

    /// Short title for the card (e.g. "Claude wants to run:").
    public let title: String

    /// The command or tool being gated, rendered as text.
    public let subject: String

    /// The decision, or `nil` while the request is pending.
    public let resolution: Resolution?

    /// The choices available for this request. Older hosts omitted this field
    /// and decode to the default once/always/deny set.
    public let options: [Option]

    /// Optional scope text, such as a command pattern or tool name.
    public let scope: String?

    /// Creates a permission request.
    ///
    /// - Parameters:
    ///   - title: Short card title.
    ///   - subject: The gated command or tool, as text.
    ///   - resolution: The decision, or `nil` while pending.
    public init(
        title: String,
        subject: String,
        resolution: Resolution? = nil,
        options: [Option] = Self.defaultOptions,
        scope: String? = nil
    ) {
        self.title = title
        self.subject = subject
        self.resolution = resolution
        self.options = options
        self.scope = scope
    }

    public static let defaultOptions: [Option] = [
        Option(label: "Allow once", detail: "Approve only this request."),
        Option(label: "Always allow", detail: "Approve future matching requests."),
        Option(label: "Allow all", detail: "Approve all matching actions in this session."),
        Option(label: "Deny")
    ]

    private enum CodingKeys: String, CodingKey {
        case title
        case subject
        case resolution
        case options
        case scope
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        subject = try container.decode(String.self, forKey: .subject)
        resolution = try container.decodeIfPresent(Resolution.self, forKey: .resolution)
        options = try container.decodeIfPresent([Option].self, forKey: .options) ?? Self.defaultOptions
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
    }
}
