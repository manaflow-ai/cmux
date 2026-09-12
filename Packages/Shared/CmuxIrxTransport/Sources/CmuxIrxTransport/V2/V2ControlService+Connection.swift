import Foundation

extension V2ControlService {
    func run(_ run: UUID) async {
        var attempt = 0
        while runID == run, !Task.isCancelled {
            do {
                if !loaded {
                    let restored = try await store.load(identity: descriptor.identity)
                    try assertCurrent(run)
                    if let restored {
                        guard restored.identity == descriptor.identity,
                              restored.device?.descriptor.endpointID == nil || restored.device?.descriptor.endpointID == descriptor.endpointID else {
                            throw V2ControlFailure.scopeMismatch
                        }
                        cache = restored
                    }
                    loaded = true
                    publish()
                }
                try checkCooldown("session.open.v1")
                do {
                    try await open(run: run)
                } catch {
                    guard permitsHTTPRecovery(error) else { throw error }
                    let old = socket
                    socket = nil
                    socketID = nil
                    receiveTask?.cancel()
                    receiveTask = nil
                    finishAll(throwing: V2ControlFailure.unavailable)
                    await old?.close()
                    try assertCurrent(run)
                    try await openHTTP(run: run)
                    // Retry the preferred push channel while HTTP serves requests.
                    try await dependencies.sleep(60)
                    continue
                }
                try assertCurrent(run)
                attempt = 0
                if let receiver = receiveTask { await receiver.value }
                try assertCurrent(run)
                throw failure ?? V2ControlFailure.unavailable
            } catch {
                guard runID == run, !Task.isCancelled else { return }
                let mapped = mapFailure(error)
                record(mapped, schema: "session.open.v1")
                let old = socket
                socket = nil
                socketID = nil
                receiveTask?.cancel()
                receiveTask = nil
                cancelMaintenance()
                finishAll(throwing: mapped)
                await old?.close()
                guard runID == run else { return }
                if terminal(mapped) {
                    status = .stopped
                    runID = nil
                    runTask = nil
                    publish()
                    return
                }
                if isAuthenticationFailure(mapped) { forceStackOnNextSetup = true }
                status = .backingOff
                publish()
                let seconds = retryDelay(mapped, attempt: attempt)
                attempt += 1
                do { try await dependencies.sleep(seconds) }
                catch { return }
            }
        }
    }

    private func open(run: UUID) async throws {
        status = .connecting
        publish()
        let requestID = UUID().uuidString.lowercased()
        let (setup, authorization) = try await makeSetup(requestID: requestID, run: run)
        let setupBytes = try codec.encode(setup)
        guard setupBytes.count <= 16 * 1024 else { throw V2ControlFailure.capacityExceeded }
        var components = URLComponents(url: configuration.baseURL.appendingPathComponent("v2/control/socket"), resolvingAgainstBaseURL: false)
        components?.scheme = configuration.baseURL.scheme == "https" ? "wss" : "ws"
        guard let url = components?.url else { throw V2ControlFailure.scopeMismatch }
        var request = URLRequest(url: url)
        request.timeoutInterval = configuration.requestTimeout
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(codec.base64URL(setupBytes), forHTTPHeaderField: "x-cmux-v2-setup")
        let opened = V2OrderedSocket(transport: try await dependencies.connect(request))
        guard runID == run, !Task.isCancelled else {
            await opened.close()
            throw V2ControlFailure.stopped
        }
        let connection = UUID()
        socket = opened
        socketID = connection
        receiveTask = Task { [weak self] in await self?.receive(run: run, connection: connection, socket: opened) }
        let bytes = try await exchange(data: nil, requestID: requestID, schemaID: "session.open.v1", run: run)
        let ready = try JSONDecoder().decode(V2ReadyResponse.self, from: bytes)
        try assertCurrent(run)
        httpMode = false
        try await acceptReady(ready, run: run)
    }

    func acceptReady(_ ready: V2ReadyResponse, run: UUID) async throws {
        if let record = ready.device { try acceptDevice(record) }
        if let ticket = ready.ticket { cache.ticket = ticket }
        if let challenge = ready.challenge {
            try await enroll(challenge: challenge, run: run)
        } else if ready.device == nil {
            throw V2ControlFailure.invalidWireData
        }
        try assertCurrent(run)
        cache.authorityRevoked = false
        if cache.device?.descriptor.metadata != descriptor.metadata {
            do { try await updateMetadata(descriptor.metadata) }
            catch { record(mapFailure(error), schema: "device.metadata.v1") }
        }
        try await persist(run: run)
        status = .ready
        failure = nil
        publish()
        requestDirectoryRefresh(run: run)
        scheduleMaintenance(run: run)
    }

    func makeSetup(requestID: String, run: UUID) async throws -> (V2SocketSetup, String) {
        let unsigned = V2SocketSetup(device: descriptor, haveRevision: cache.directory?.revision, proof: nil, requestID: requestID, schemaID: .sessionOpenV1)
        let ticket = cache.ticket.flatMap { $0.expiresAt > Int(dependencies.now().timeIntervalSince1970) + 30 ? $0 : nil }
        let authorization: String
        if let ticket, !forceStackOnNextSetup, !cache.authorityRevoked {
            authorization = "IrohTicket " + ticket.token
        } else {
            let token = try await stackToken(forceRefresh: forceStackOnNextSetup, run: run)
            try assertCurrent(run)
            authorization = "Bearer " + token
            forceStackOnNextSetup = false
        }
        // Also sign first setup. If enrollment committed but its reply was lost,
        // the server can recognize this key without an extra enrollment round.
        let issuedAt = Int(dependencies.now().timeIntervalSince1970)
        let nonce = codec.newProofNonce()
        let bytes = try codec.request(device: descriptor, requestID: requestID, issuedAt: issuedAt, body: unsigned, nonce: nonce)
        let signature = try await dependencies.sign(bytes)
        try assertCurrent(run)
        let proof = V2DeviceProof(issuedAt: issuedAt, nonce: nonce, requestID: requestID, signature: codec.base64URL(signature))
        return (V2SocketSetup(device: descriptor, haveRevision: unsigned.haveRevision, proof: proof, requestID: requestID, schemaID: .sessionOpenV1), authorization)
    }

    private func enroll(challenge: V2Challenge, run: UUID) async throws {
        let signature = try await dependencies.sign(codec.enrollment(device: descriptor, challenge: challenge))
        try assertCurrent(run)
        let request = V2RegisterRequest(
            challengeID: challenge.challengeID, device: descriptor, nonce: challenge.nonce,
            requestID: UUID().uuidString.lowercased(), schemaID: .deviceRegisterV1,
            signature: codec.base64URL(signature)
        )
        let response = try await perform(request, requestID: request.requestID, schemaID: request.schemaID.rawValue, response: V2RegisteredResponse.self, run: run)
        try assertCurrent(run)
        try acceptDevice(response.device)
    }

    func acceptDevice(_ record: V2DeviceRecord) throws {
        guard record.descriptor.identity == descriptor.identity,
              record.descriptor.endpointID == descriptor.endpointID,
              record.descriptor.identityGeneration == descriptor.identityGeneration,
              !record.revoked else { throw V2ControlFailure.scopeMismatch }
        cache.device = record
    }

    private struct Envelope: Decodable {
        let schemaId: String
        let requestId: String?
        let deliveryReceipt: V2DeliveryReceipt?
    }

    private func receive(run: UUID, connection: UUID, socket: any V2ControlSocket) async {
        do {
            while runID == run, socketID == connection, !Task.isCancelled {
                let data = try await socket.receive()
                try assertCurrent(run)
                guard socketID == connection else { return }
                guard data.count <= 2 * 1024 * 1024 else { throw V2ControlFailure.capacityExceeded }
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                if let receipt = envelope.deliveryReceipt {
                    acknowledge(receipt, run: run, connection: connection, socket: socket)
                }
                switch envelope.schemaId {
                case "directory.changed.v1":
                    let change = try JSONDecoder().decode(V2ChangedResponse.self, from: data)
                    guard change.teamID == descriptor.identity.teamID else { throw V2ControlFailure.scopeMismatch }
                    wantedDirectoryRevision = max(wantedDirectoryRevision, change.revision)
                    requestDirectoryRefresh(run: run)
                case "device.revoked.v1":
                    let change = try JSONDecoder().decode(V2RevokedResponse.self, from: data)
                    guard change.teamID == descriptor.identity.teamID else { throw V2ControlFailure.scopeMismatch }
                    applyRevocation(change)
                    publish()
                    try await persist(run: run)
                    if cache.authorityRevoked {
                        throw V2ControlFailure.server(V2ErrorResponse(code: .deviceRevoked, requestID: "revocation", retryable: false, retryAfterMS: nil, schemaID: .errorV1))
                    }
                    requestDirectoryRefresh(run: run)
                case "workspace.changed.v1":
                    let change = try JSONDecoder().decode(V2WorkspaceChangedResponse.self, from: data)
                    guard change.teamID == descriptor.identity.teamID else { throw V2ControlFailure.scopeMismatch }
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            _ = try await self.refreshWorkspace(vmID: change.vmID)
                        } catch {
                            await self.record(mapFailure(error), schema: "workspace.get.v1")
                        }
                    }
                case "error.v1":
                    let response = try JSONDecoder().decode(V2ErrorResponse.self, from: data)
                    let error = V2ControlFailure.server(response)
                    let schema = pending[response.requestID]?.schemaID ?? "session.open.v1"
                    record(error, schema: schema)
                    if [.teamAccessRevoked, .deviceRevoked].contains(response.code) {
                        revokeAuthority()
                        publish()
                        try await persist(run: run)
                    }
                    finish(response.requestID, result: .failure(error))
                    if terminal(error) { throw error }
                    if [.resyncRequired, .slowConsumer].contains(response.code) { requestDirectoryRefresh(run: run) }
                default:
                    guard let id = envelope.requestId else { throw V2ControlFailure.invalidWireData }
                    // Replies to cancelled/timed-out operations are harmless and cannot change state.
                    finish(id, result: .success(data))
                }
            }
        } catch {
            await socketFailed(error, run: run, connection: connection)
        }
    }

    func socketFailed(_ error: any Error, run: UUID, connection: UUID) async {
        guard runID == run, socketID == connection else { return }
        failure = mapFailure(error)
        if case .socketClosed(1008, let reason) = failure,
           ["device_revoked", "team_access_revoked"].contains(reason ?? "") {
            revokeAuthority()
            try? await persist(run: run)
            guard runID == run, socketID == connection else { return }
        }
        let old = socket
        socket = nil
        socketID = nil
        finishAll(throwing: failure ?? .unavailable)
        publish()
        await old?.close()
    }

    private func applyRevocation(_ revoked: V2RevokedResponse) {
        if revoked.deviceRecordID == cache.device?.deviceRecordID { revokeAuthority(); return }
        if let directory = cache.directory {
            cache.directory = V2Directory(
                devices: directory.devices.filter { $0.deviceRecordID != revoked.deviceRecordID },
                inboundPeers: directory.inboundPeers?.filter { $0.device.deviceRecordID != revoked.deviceRecordID },
                issuedAt: directory.issuedAt, nextCursor: directory.nextCursor,
                permissionExpiresAt: directory.permissionExpiresAt, relayURLs: directory.relayURLs,
                revision: max(directory.revision, revoked.revision), teamID: directory.teamID
            )
        }
        wantedDirectoryRevision = max(wantedDirectoryRevision, revoked.revision)
    }

    func revokeAuthority() {
        cache.authorityRevoked = true
        cache.ticket = nil
        cache.relayCredentials = []
        cache.directory = nil
    }

    func mapFailure(_ error: any Error) -> V2ControlFailure {
        if let error = error as? V2ControlFailure { return error }
        if error is DecodingError { return .invalidWireData }
        return .unavailable
    }

    func isAuthenticationFailure(_ error: V2ControlFailure) -> Bool {
        if case .server(let response) = error { return [.unauthorized, .ticketExpired].contains(response.code) }
        if case .http(let status, _) = error { return status == 401 }
        return false
    }

    func terminal(_ error: V2ControlFailure) -> Bool {
        switch error {
        case .scopeMismatch, .persistenceFailed, .capacityExceeded, .invalidWireData: return true
        case .socketClosed(let code, _): return code == 1008 || code == 1009
        case .server(let response):
            return [.teamAccessRevoked, .deviceRevoked, .identityMismatch, .environmentMismatch, .keyReplacementRequired, .endpointAlreadyOwned, .invalidDeviceProof].contains(response.code)
        case .http(let status, _): return [400, 403, 404, 405, 413, 415].contains(status)
        default: return false
        }
    }

    func retryDelay(_ error: V2ControlFailure, attempt: Int) -> TimeInterval {
        var delay = min(60, pow(2, Double(min(attempt, 6)))) * (0.8 + 0.4 * dependencies.jitter())
        if case .socketClosed(let code, _) = error, code == 1013 || code == 1000 {
            delay = max(delay, 60 * (1 + 0.2 * dependencies.jitter()))
        }
        if case .http(let status, let retryAfter) = error, status == 429 { delay = max(delay, retryAfter ?? 60) }
        if case .cooldown(_, let until) = error { delay = max(delay, until.timeIntervalSince(dependencies.now())) }
        if let until = [cooldowns["session.open.v1"], cooldowns["session.open"]].compactMap({ $0 }).max() {
            delay = max(delay, until.timeIntervalSince(dependencies.now()))
        }
        return delay
    }
}
