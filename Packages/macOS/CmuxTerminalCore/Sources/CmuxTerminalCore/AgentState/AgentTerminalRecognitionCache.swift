/// Caches only successful agent-family recognition for one process generation.
///
/// Some agents replace their process title after launch. An unresolved generation
/// must therefore remain eligible for another snapshot when terminal output changes.
public struct AgentTerminalRecognitionCache: Sendable {
    private var identity: AgentTerminalProcessIdentity?
    private var familyID: String?

    public init() {}

    public func requiresSnapshot(for identity: AgentTerminalProcessIdentity) -> Bool {
        self.identity != identity || familyID == nil
    }

    public func familyID(for identity: AgentTerminalProcessIdentity) -> String? {
        guard self.identity == identity else { return nil }
        return familyID
    }

    public mutating func store(identity: AgentTerminalProcessIdentity, familyID: String?) {
        self.identity = identity
        self.familyID = familyID
    }
}
