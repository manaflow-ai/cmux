import Foundation
@testable import CmuxIrxTransport

actor V2TestSocket: V2ControlSocket {
    let device: V2DeviceDescriptor
    let now: Int
    var queued: [Data] = []
    var receiver: CheckedContinuation<Data, any Error>?
    var closed = false
    var closeCount = 0
    var pingCount = 0
    var sentSchemas: [String] = []
    var rejectedRelay: V2ErrorCode?
    var suspendRelay = false
    var deferredRelay: V2RelayRequest?
    var relayObserved: CheckedContinuation<Void, Never>?
    var relayOrdinal = 0
    let record: V2DeviceRecord

    init(device: V2DeviceDescriptor, now: Int) {
        self.device = device
        self.now = now
        record = V2DeviceRecord(descriptor: device, deviceRecordID: "device-record", revision: 1, revoked: false)
    }

    func prepare(_ setup: V2SocketSetup, enrolled: Bool) throws {
        try push(V2ReadyResponse(
            challenge: enrolled ? nil : V2Challenge(challengeID: "challenge", expiresAt: now + 1800, nonce: String(repeating: "n", count: 43), payloadHash: String(repeating: "a", count: 64)),
            device: enrolled ? record : nil, requestID: setup.requestID, schemaID: .sessionReadyV1,
            sessionID: "session", teamRevision: 1,
            ticket: V2Ticket(expiresAt: now + 3600, refreshAfter: now + 3300, token: "initial-ticket")
        ))
    }

    func send(_ data: Data) throws {
        let header = try JSONDecoder().decode(Header.self, from: data)
        sentSchemas.append(header.schemaId)
        switch header.schemaId {
        case "device.register.v1":
            try push(V2RegisteredResponse(device: record, requestID: header.requestId, schemaID: .deviceRegisteredV1))
        case "ticket.request.v1":
            try push(V2TicketResponse(requestID: header.requestId, schemaID: .ticketResultV1, ticket: V2Ticket(expiresAt: now + 3600, refreshAfter: now + 3300, token: "replacement-ticket")))
        case "relay.request.v1":
            let request = try JSONDecoder().decode(V2RelayRequest.self, from: data)
            if suspendRelay {
                deferredRelay = request
                relayObserved?.resume()
                relayObserved = nil
                return
            }
            try relayReply(request)
        case "directory.request.v1":
            try push(V2DirectoryResponse(directory: V2Directory(devices: [record], issuedAt: now, nextCursor: nil, permissionExpiresAt: now + 3600, relayURLs: ["https://relay.example.com/"], revision: 1, teamID: device.identity.teamID), requestID: header.requestId, schemaID: .directoryResultV1))
        default:
            try push(V2CompletedResponse(requestID: header.requestId, revision: 2, schemaID: .operationCompletedV1))
        }
    }

    func receive() async throws -> Data {
        if !queued.isEmpty { return queued.removeFirst() }
        if closed { throw V2ControlFailure.unavailable }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func ping() throws {
        guard !closed else { throw V2ControlFailure.unavailable }
        pingCount += 1
    }

    func close() {
        closed = true
        closeCount += 1
        receiver?.resume(throwing: V2ControlFailure.unavailable)
        receiver = nil
    }

    func push<Value: Encodable>(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: data)
        } else { queued.append(data) }
    }

    func rejectRelay(_ code: V2ErrorCode?) { rejectedRelay = code }
    func holdRelayReplies() { suspendRelay = true }
    func waitForHeldRelay() async {
        if deferredRelay != nil { return }
        await withCheckedContinuation { relayObserved = $0 }
    }
    func releaseRelayReply() throws {
        suspendRelay = false
        if let request = deferredRelay {
            deferredRelay = nil
            try relayReply(request)
        }
    }

    private func relayReply(_ request: V2RelayRequest) throws {
        if let rejectedRelay {
            try push(V2ErrorResponse(code: rejectedRelay, requestID: request.requestID, retryable: true, retryAfterMS: 60_000, schemaID: .errorV1))
        } else {
            relayOrdinal += 1
            try push(V2RelayResponse(credentials: [V2RelayCredential(expiresAt: now + 1800, refreshAfter: now + 1500, relayURL: "https://relay.example.com/", token: "relay-\(relayOrdinal)")], requestID: request.requestID, schemaID: .relayResultV1))
        }
    }

    private struct Header: Decodable { let schemaId: String; let requestId: String }
}
