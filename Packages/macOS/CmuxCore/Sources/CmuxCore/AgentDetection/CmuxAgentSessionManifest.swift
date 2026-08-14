/// Optional persistence contract for one detected agent.
public struct CmuxAgentSessionManifest: Codable, Equatable, Hashable, Sendable {
    /// Source used to extract a durable session identifier.
    public var sessionIdSource: String?
    /// Resume command template.
    public var resumeCommand: String?
    /// Optional fork command template.
    public var forkCommand: String?
    /// Working-directory policy (`preserve` or `ignore`; `none` aliases `ignore`).
    public var cwd: String?
    /// Optional directory containing durable session records.
    public var sessionDirectory: String?

    /// Whether this value defines the complete minimum restoration contract.
    public var supportsRestoration: Bool {
        sessionIdSource != nil && resumeCommand != nil
    }

    /// Creates a persistence contract.
    public init(
        sessionIdSource: String? = nil,
        resumeCommand: String? = nil,
        forkCommand: String? = nil,
        cwd: String? = nil,
        sessionDirectory: String? = nil
    ) {
        self.sessionIdSource = sessionIdSource
        self.resumeCommand = resumeCommand
        self.forkCommand = forkCommand
        self.cwd = cwd
        self.sessionDirectory = sessionDirectory
    }
}
