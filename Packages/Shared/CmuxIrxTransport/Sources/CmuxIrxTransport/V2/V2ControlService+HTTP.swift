import Foundation

extension V2ControlService {
    func openHTTP(run: UUID) async throws {
        let requestID = UUID().uuidString.lowercased()
        let (setup, authorization) = try await makeSetup(requestID: requestID, run: run)
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v2/control/session"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeout
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try codec.encode(setup)
        let reply = try await dependencies.http(request)
        try assertCurrent(run)
        let bytes = try decodeHTTP(reply, schema: "session.open.v1")
        let ready = try JSONDecoder().decode(V2ReadyResponse.self, from: bytes)
        httpMode = true
        try await acceptReady(ready, run: run)
    }

    func sendHTTP(data: Data, requestID: String, schema: String, run: UUID) async throws -> Data {
        try assertCurrent(run)
        try checkCooldown(schema)
        guard data.count <= 16 * 1024 else { throw V2ControlFailure.capacityExceeded }
        let unsigned = V2SocketSetup(device: descriptor, haveRevision: cache.directory?.revision, proof: nil, requestID: requestID, schemaID: .sessionOpenV1)
        let issuedAt = Int(dependencies.now().timeIntervalSince1970)
        let nonce = codec.newProofNonce()
        let signature = try await dependencies.sign(codec.httpRequest(device: descriptor, setup: unsigned, issuedAt: issuedAt, request: data, nonce: nonce))
        try assertCurrent(run)
        let proof = V2DeviceProof(issuedAt: issuedAt, nonce: nonce, requestID: requestID, signature: codec.base64URL(signature))
        let setup = V2SocketSetup(device: descriptor, haveRevision: unsigned.haveRevision, proof: proof, requestID: requestID, schemaID: .sessionOpenV1)
        let authorization: String
        if let ticket = cache.ticket, ticket.expiresAt > issuedAt, !cache.authorityRevoked {
            authorization = "IrohTicket " + ticket.token
        } else {
            authorization = "Bearer " + (try await stackToken(forceRefresh: false, run: run))
        }
        try assertCurrent(run)
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v2/requests"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeout
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(codec.base64URL(try codec.encode(setup)), forHTTPHeaderField: "x-cmux-v2-setup")
        request.httpBody = data
        let response = try await dependencies.http(request)
        try assertCurrent(run)
        do { return try decodeHTTP(response, schema: schema) }
        catch {
            if cache.authorityRevoked { try await persist(run: run) }
            throw error
        }
    }

    func decodeHTTP(_ response: V2HTTPResponse, schema: String) throws -> Data {
        guard response.body.count <= 2 * 1024 * 1024 else { throw V2ControlFailure.capacityExceeded }
        if let body = try? JSONDecoder().decode(V2ErrorResponse.self, from: response.body) {
            let error = V2ControlFailure.server(body)
            if [.teamAccessRevoked, .deviceRevoked].contains(body.code) { revokeAuthority() }
            record(error, schema: schema)
            throw error
        }
        guard (200..<300).contains(response.status) else {
            let error = V2ControlFailure.http(status: response.status, retryAfter: response.retryAfter)
            if response.status == 429 {
                cooldowns[operation(schema)] = dependencies.now().addingTimeInterval(max(1, response.retryAfter ?? 60))
            }
            record(error, schema: schema)
            throw error
        }
        return response.body
    }

    func permitsHTTPRecovery(_ error: any Error) -> Bool {
        switch error {
        case V2ControlFailure.unavailable, V2ControlFailure.requestTimedOut: return true
        case V2ControlFailure.http(let status, _): return status >= 500 || status == 426
        case is URLError: return true
        default: return false
        }
    }
}
