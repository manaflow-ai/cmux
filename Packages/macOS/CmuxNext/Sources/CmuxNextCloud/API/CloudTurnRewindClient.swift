public import Foundation

/// Fixed owner reads and rewind requests for a workspace's new-platform machine.
/// The native app supplies the token; it never becomes part of a control-socket response.
public struct CloudTurnRewindClient: Sendable {
    private let origin: URL
    private let token: @Sendable () async throws -> String
    private let transport: URLSession

    public init(origin: URL, token: @escaping @Sendable () async throws -> String) {
        self.origin = origin
        self.token = token
        transport = CloudOwnerAPIClient.transport
    }

    init(origin: URL, token: @escaping @Sendable () async throws -> String, transport: URLSession) {
        self.origin = origin
        self.token = token
        self.transport = transport
    }

    /// Enroll an existing owner-verified Cloud carrier before the first agent attachment.
    /// This endpoint never allocates a machine. Its idempotency scope includes the workspace,
    /// logical machine and generation, so relaunch can safely repeat the same request.
    public struct Enrollment: Decodable, Sendable {
        public let connection: CloudWorkspaceConnection
        public let reconnectRequired: Bool
        private enum CodingKeys: String, CodingKey { case reconnectRequired }
        public init(from decoder: any Decoder) throws {
            connection = try CloudWorkspaceConnection(from: decoder)
            reconnectRequired = try decoder.container(keyedBy: CodingKeys.self).decode(Bool.self, forKey: .reconnectRequired)
        }
    }

    public func importWorkspace(workspace: String, machine: String, carrier: String, generation: Int) async throws -> Enrollment {
        guard Self.valid(workspace), Self.valid(machine), generation >= 0, carrier.utf8.count == 23,
              carrier.range(of: #"^vm_[a-z0-9]{20}$"#, options: .regularExpression) != nil
        else { throw Failure.invalidScope }
        let data = try await request(path: "/v1/workspaces/\(workspace)/machine/import", body: [
            "carrierMachine": carrier, "expectedMachine": machine, "expectedGeneration": generation,
            "clientKey": "native-workspace-import-v1",
        ])
        let enrollment = try JSONDecoder().decode(Enrollment.self, from: data)
        let connection = try enrollment.connection.checked(machine: machine)
        // Zero is the absence fence on first import; the new ledger starts at one.
        let expectedGeneration = generation == 0 ? 1 : generation
        guard connection.generation == expectedGeneration, connection.connectionMachine == carrier else { throw Failure.invalidReply }
        return enrollment
    }

    /// Reads the external generation and capture ledger for one workspace.
    public func state(workspace: String) async throws -> Data {
        try await request(path: path(workspace), body: nil)
    }

    /// The stable logical machine bound to this workspace, independent of provider replacements.
    public func machine(workspace: String) async throws -> Data {
        guard Self.valid(workspace) else { throw Failure.invalidScope }
        return try await request(path: "/v1/workspaces/\(workspace)/machine", body: nil)
    }

    /// The transport target behind the logical machine, resolved by the owner control plane.
    public func connection(workspace: String) async throws -> Data {
        guard Self.valid(workspace) else { throw Failure.invalidScope }
        return try await request(path: "/v1/workspaces/\(workspace)/machine/connection", body: nil)
    }

    /// Restores the selected capture only while the expected machine and generation still hold.
    public func rewind(workspace: String, session: String, turn: String, machine: String, generation: Int, key: String) async throws -> Data {
        guard Self.valid(session), Self.valid(turn), Self.valid(machine), Self.valid(key), key.utf8.count <= 128,
              generation >= 0 else { throw Failure.invalidScope }
        return try await request(path: path(workspace) + "/\(turn)/rewind", body: [
            "session": session, "clientKey": key, "expectedMachine": machine, "expectedGeneration": generation,
        ])
    }

    public enum Failure: Error, Sendable {
        case invalidScope
        case http(Int)
        case invalidReply
    }

    private func path(_ workspace: String) throws -> String {
        guard Self.valid(workspace) else { throw Failure.invalidScope }
        return "/v1/workspaces/\(workspace)/machine/turns"
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0)
        }
    }

    private func request(path: String, body: [String: Any]?) async throws -> Data {
        guard origin.scheme == "https", origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              let url = URL(string: origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)
        else { throw Failure.invalidScope }
        var request = URLRequest(url: url, timeoutInterval: 240)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidReply }
        guard (200..<300).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
        return data
    }
}
