public import Foundation

/// Native owner-authenticated forwarding for a prepared turn on one workspace machine.
/// The owner token never leaves this client; only the single-turn capability reaches the guest.
public struct CloudTurnOwnerClient: Sendable {
    public typealias Token = @Sendable () async throws -> String
    private let baseURL: URL
    private let token: Token
    private let transport: URLSession

    public init(baseURL: URL, token: @escaping Token) {
        self.baseURL = baseURL
        self.token = token
        transport = CloudOwnerAPIClient.transport
    }

    init(baseURL: URL, token: @escaping Token, transport: URLSession) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    public struct Scope: Codable, Sendable {
        public let workspace: String
        public let machine: String
        public let generation: Int
    }

    /// Owner-verified generation, read before the guest reserves a turn. It lets a restored
    /// daemon distinguish its old RAM queue from reservations in the current generation.
    public func state(workspace: String, machine: String) async throws -> Data {
        struct State: Decodable { let machineId: String; let generation: Int }
        guard Self.isID(workspace), Self.isID(machine) else { throw Failure.scope }
        let data = try await request("/v1/workspaces/\(workspace)/machine/turns", body: nil)
        let state = try JSONDecoder().decode(State.self, from: data)
        guard state.machineId == machine, state.generation >= 0 else { throw Failure.scope }
        return try JSONEncoder().encode(Scope(workspace: workspace, machine: machine, generation: state.generation))
    }

    /// The backend authorizes only this preparation attempt. Relaunch reacquires it with native
    /// owner authentication; no durable person key or owner credential is sent to the guest.
    public func authorizePreparation(workspace: String, machine: String, session: String, prompt: String) async throws -> Data {
        guard Self.isID(session), Self.isID(prompt), prompt.utf8.count <= 128 else { throw Failure.scope }
        let ownerState = try await self.state(workspace: workspace, machine: machine)
        let state = try JSONDecoder().decode(Scope.self, from: ownerState)
        let attempt = UUID().uuidString.lowercased()
        let authorization = try await request("/v1/workspaces/\(workspace)/machine/turns/\(prompt)/capability", body: [
            "session": session, "expectedMachine": machine, "expectedGeneration": state.generation,
            "purpose": "prepare", "attemptId": attempt,
        ])
        let mint = try JSONDecoder().decode(Mint.self, from: authorization)
        guard mint.workspace == workspace, mint.machine == machine, mint.session == session, mint.turn == prompt,
              mint.generation == state.generation, mint.purpose == "prepare", mint.attemptId == attempt,
              mint.capability.hasPrefix("trc_"), mint.capability.utf8.count == 47 else { throw Failure.scope }
        return try JSONSerialization.data(withJSONObject: ["workspace": workspace, "machine": machine,
            "generation": state.generation, "turn": prompt, "attemptId": attempt,
            "authorization": JSONSerialization.jsonObject(with: authorization)])
    }

    /// Captures the trusted workspace's machine, then mints its one-use execution capability.
    /// `prepared` comes from the owning daemon; neither a workspace nor a machine is taken from it.
    public func prepare(workspace: String, machine: String, session: String, prompt: String, prepared: Data,
                        ownerState: Data? = nil,
                        verified: (@Sendable () async throws -> Void)? = nil) async throws -> Data {
        struct Prepared: Decodable {
            let turn: String; let session: String; let generation: Int?; let attempt_id: String?
        }
        struct Attempt: Decodable { let turn: String?; let attemptId: String? }
        struct Capture: Decodable {
            let workspace: String; let session: String; let turn: String
            let machineId: String; let machineGeneration: Int; let status: String
        }
        let turn = try JSONDecoder().decode(Prepared.self, from: prepared)
        guard turn.session == session, Self.isID(turn.turn), Self.isID(workspace), Self.isID(machine),
              Self.isID(session), Self.isID(prompt), prompt.utf8.count <= 128 else { throw Failure.scope }
        let path = "/v1/workspaces/\(workspace)/machine/turns"
        let stateData: Data
        if let ownerState { stateData = ownerState }
        else { stateData = try await self.state(workspace: workspace, machine: machine) }
        let state = try JSONDecoder().decode(Scope.self, from: stateData)
        guard state.workspace == workspace, state.machine == machine, state.generation >= 0 else { throw Failure.scope }
        let attempt = try JSONDecoder().decode(Attempt.self, from: stateData)
        if let authorizedTurn = attempt.turn {
            guard turn.turn == authorizedTurn, turn.generation == state.generation,
                  turn.attempt_id == attempt.attemptId else { throw Failure.scope }
        }
        // Persist native ownership before reserving a capture: a failed local write must not
        // strand a minted capability that no guest ever received.
        try await verified?()
        let scope: [String: Any] = ["session": session, "expectedMachine": machine, "expectedGeneration": state.generation]
        let captureData = try await request(path + "/\(turn.turn)/snapshot", body: scope.merging(["clientKey": prompt]) { _, new in new })
        let capture = try JSONDecoder().decode(Capture.self, from: captureData)
        guard capture.workspace == workspace, capture.session == session, capture.turn == turn.turn,
              capture.machineId == machine, capture.machineGeneration == state.generation, capture.status == "ready" else { throw Failure.scope }
        do {
            var execution = scope
            if let attemptId = attempt.attemptId { execution["purpose"] = "execute"; execution["attemptId"] = attemptId }
            let capability = try await request(path + "/\(turn.turn)/capability", body: execution)
            let mint = try JSONDecoder().decode(Mint.self, from: capability)
            guard mint.workspace == workspace, mint.machine == machine, mint.session == session,
                  mint.turn == turn.turn, mint.generation == state.generation,
                  mint.capability.hasPrefix("trc_"), mint.capability.utf8.count == 47 else { throw Failure.scope }
            if let attemptId = attempt.attemptId {
                guard mint.purpose == "execute", mint.attemptId == attemptId else { throw Failure.scope }
            }
            return capability
        } catch {
            // No guest has seen the capability yet: releasing this exact reserved capture is safe.
            // A failed prompt submission is different and is never released here: it may be running.
            _ = try? await request(path + "/\(turn.turn)/finish", body: scope)
            throw error
        }
    }

    private struct Mint: Decodable {
        let capability: String; let workspace: String; let machine: String
        let session: String; let turn: String; let generation: Int
        let purpose: String?; let attemptId: String?
    }

    public enum Failure: Error, Sendable {
        case scope
        case refused(Int)
        case invalidResponse
    }

    private static func isID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0)
        } && value != "." && value != ".."
    }

    private func request(_ path: String, body: [String: Any]?) async throws -> Data {
        guard baseURL.scheme == "https", baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil,
              let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)
        else { throw Failure.scope }
        var request = URLRequest(url: url, timeoutInterval: 240)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw Failure.refused(response.statusCode) }
        return data
    }
}
