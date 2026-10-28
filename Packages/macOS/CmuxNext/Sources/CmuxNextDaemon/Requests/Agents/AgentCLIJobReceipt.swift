import Foundation

/// A durable terminal creation receipt, not proof of update completion.
/// Contains public resource identities only; no argv, credentials or host IDs.
public nonisolated struct AgentCLIJobReceipt: Decodable, Sendable, Equatable {
    /// The machine that accepted the owner's identity condition.
    public let machine: ResourceID
    /// The session whose creation journal owns the job.
    public let session: ResourceID
    /// The owner-selected CLI family that this intent updates.
    public let cli: AgentCLIFamily
    /// Public identities for the created terminal and its initial view.
    public let path: Path
    /// The exact creation revision, decoded from decimal text.
    public let revision: UInt64
    /// Whether the owner returned a previously recorded creation.
    public let replayed: Bool

    /// The existing public created-terminal path within this receipt's session.
    public struct Path: Decodable, Sendable, Equatable {
        /// The dedicated job workspace.
        public let workspaceID: ResourceID
        /// The job terminal's initial screen.
        public let screenID: ResourceID
        /// The job terminal's initial pane.
        public let paneID: ResourceID
        /// The initial terminal view; it may later be closed.
        public let tabID: ResourceID
        /// The durable terminal identity used to obtain the actual exit outcome.
        public let terminalID: ResourceID

        private enum CodingKeys: String, CodingKey {
            case kind, workspaceID = "workspace_id", screenID = "screen_id"
            case paneID = "pane_id", tabID = "tab_id", terminalID = "terminal_id"
        }

        /// Decodes only a canonical public terminal path, without private host identity.
        public init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            guard try fields.decode(String.self, forKey: .kind) == "terminal" else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Expected a terminal job path"))
            }
            workspaceID = try fields.decode(ResourceID.self, forKey: .workspaceID)
            screenID = try fields.decode(ResourceID.self, forKey: .screenID)
            paneID = try fields.decode(ResourceID.self, forKey: .paneID)
            tabID = try fields.decode(ResourceID.self, forKey: .tabID)
            terminalID = try fields.decode(ResourceID.self, forKey: .terminalID)
            guard [(workspaceID, "ws"), (screenID, "screen"), (paneID, "pane"),
                   (tabID, "tab"), (terminalID, "term")].allSatisfy({ AgentCLIJobReceipt.validID($0.0, scope: $0.1) }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Invalid public job path"))
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case machine, session, cli, path, revision, replayed }

    /// Requires a canonical machine/session, known CLI and exact decimal revision.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        machine = try fields.decode(ResourceID.self, forKey: .machine)
        session = try fields.decode(ResourceID.self, forKey: .session)
        cli = try fields.decode(AgentCLIFamily.self, forKey: .cli)
        path = try fields.decode(Path.self, forKey: .path)
        replayed = try fields.decode(Bool.self, forKey: .replayed)
        let decimal = try fields.decode(String.self, forKey: .revision)
        guard Self.validID(machine, scope: "machine"), Self.validID(session, scope: "session"),
              cli != .unknown, let revision = UInt64(decimal), String(revision) == decimal else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid owner job receipt"))
        }
        self.revision = revision
    }

    package static func validID(_ id: ResourceID, scope: String) -> Bool {
        let prefix = scope + "_"
        let value = id.rawValue
        return value.hasPrefix(prefix) && value.utf8.count == prefix.utf8.count + 32
            && value.dropFirst(prefix.count).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
