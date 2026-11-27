import Foundation

/// An immutable, non-secret intent written before contacting an update owner.
public nonisolated struct AgentCLIUpdateIntent: Codable, Sendable, Equatable {
    public let key: String
    public let rootKey: String
    public let machine: ResourceID
    public let session: ResourceID
    public let cli: String
    public let profiles: [String]

    public var family: AgentCLIFamily { AgentCLIFamily(rawValue: cli) ?? .unknown }

    public init(key: String, rootKey: String, machine: ResourceID, session: ResourceID,
                cli: AgentCLIFamily, profiles: [String]) throws {
        func valid(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 128
                && !value.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
        guard valid(key), valid(rootKey), cli != .unknown,
              AgentCLIJobReceipt.validID(machine, scope: "machine"), AgentCLIJobReceipt.validID(session, scope: "session"),
              profiles.count <= 128, profiles.allSatisfy(valid) else {
            throw DaemonError.malformedResponse("Invalid retained update intent")
        }
        self.key = key
        self.rootKey = rootKey
        self.machine = machine
        self.session = session
        self.cli = cli.rawValue
        self.profiles = profiles
    }

    private enum CodingKeys: String, CodingKey { case key, rootKey = "root_key", machine, session, cli, profiles }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(key: fields.decode(String.self, forKey: .key), rootKey: fields.decode(String.self, forKey: .rootKey),
            machine: fields.decode(ResourceID.self, forKey: .machine), session: fields.decode(ResourceID.self, forKey: .session),
            cli: AgentCLIFamily(rawValue: fields.decode(String.self, forKey: .cli)) ?? .unknown,
            profiles: fields.decode([String].self, forKey: .profiles))
    }
}
