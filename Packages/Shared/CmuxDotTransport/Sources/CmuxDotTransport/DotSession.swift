import CryptoKit
import Foundation

// The WebSocket relay only understands the leg header. Everything in this
// file is an application envelope carried in the opaque payload, including
// admission and the lane mux. That keeps Cloudflare blind to terminal and
// account data while still letting one account-scoped DO serve every lane.

private let dotSessionMagic = Data([0x44, 0x4f, 0x54, 0x53]) // DOTS
private let dotSessionVersion: UInt8 = 1

enum DotSessionKind: UInt8 {
    case clientHello = 1
    case serverHello = 2
    case open = 3
    case openAck = 4
    case data = 5
    case close = 6
}

struct DotSessionFrame {
    let kind: DotSessionKind
    let streamID: UInt32
    let sessionID: String
    let body: Data

    func encoded() throws -> Data {
        let session = Data(sessionID.utf8)
        guard !session.isEmpty, session.count <= 128, body.count <= DotWire.maxDataFrameBytes else {
            throw DotTransportError.protocolViolation("invalid session id")
        }
        var output = Data(capacity: 12 + session.count + body.count)
        output.append(dotSessionMagic)
        output.append(dotSessionVersion)
        output.append(kind.rawValue)
        Self.append(UInt32(streamID), to: &output)
        Self.append(UInt16(session.count), to: &output)
        output.append(session)
        output.append(body)
        return output
    }

    static func decode(_ data: Data) -> DotSessionFrame? {
        guard data.count >= 12,
              data.prefix(4) == dotSessionMagic,
              data[4] == dotSessionVersion,
              let kind = DotSessionKind(rawValue: data[5]) else { return nil }
        let streamID = data[6..<10].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let sessionLength = data[10..<12].reduce(0) { ($0 << 8) | Int($1) }
        guard sessionLength > 0, sessionLength <= 128,
              data.count >= 12 + sessionLength,
              data.count - (12 + sessionLength) <= DotWire.maxDataFrameBytes else { return nil }
        let sessionData = data.subdata(in: 12..<(12 + sessionLength))
        guard let sessionID = String(data: sessionData, encoding: .utf8),
              !sessionID.isEmpty else { return nil }
        return DotSessionFrame(
            kind: kind,
            streamID: streamID,
            sessionID: sessionID,
            body: data.subdata(in: (12 + sessionLength)..<data.count)
        )
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }
}

struct DotClientHello: Codable {
    let sessionID: String
    let identity: Data
    let ephemeral: Data
    let nonce: Data
    let grant: String
    let signature: Data
}

private struct DotServerHello: Codable {
    let sessionID: String
    let identity: Data
    let ephemeral: Data
    let nonce: Data
    let signature: Data
}

private struct DotOpenMessage: Codable {
    let descriptor: DotLaneDescriptor
}

private struct DotOpenAckMessage: Codable {
    let accepted: Bool
    let reason: String?
}

private struct DotCloseMessage: Codable {
    let writeOnly: Bool
}

private actor DotDataChannel {
    private var buffered: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var finished = false

    func next() async -> Data? {
        if !buffered.isEmpty { return buffered.removeFirst() }
        if finished { return nil }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func yield(_ data: Data) {
        guard !finished else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            buffered.append(data)
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        waiter?.resume(returning: nil)
        waiter = nil
        buffered.removeAll(keepingCapacity: false)
    }
}

private actor DotStreamImpl: DotStream {
    nonisolated let descriptor: DotLaneDescriptor
    private let id: UInt32
    private weak var session: DotSecureSession?
    private let channel: DotDataChannel
    private var closed = false
    private var writeClosed = false

    init(
        id: UInt32,
        descriptor: DotLaneDescriptor,
        session: DotSecureSession,
        channel: DotDataChannel = DotDataChannel()
    ) {
        self.id = id
        self.descriptor = descriptor
        self.session = session
        self.channel = channel
    }

    func read() async throws -> Data? {
        await channel.next()
    }

    func write(_ data: Data) async throws {
        guard !closed, !writeClosed, let session else { throw DotTransportError.sessionEnded("stream closed") }
        try await session.sendStreamData(id: id, data: data)
    }

    func closeWrite() async {
        guard !closed, !writeClosed, let session else { return }
        writeClosed = true
        await session.closeStreamWrite(id: id)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await channel.finish()
        if let session { await session.closeStream(id: id) }
    }

    func receive(_ data: Data) async {
        await channel.yield(data)
    }

    func finishInbound() async {
        await channel.finish()
    }
}

struct DotGrantClaims: Codable, Sendable {
    struct Peer: Codable, Sendable, Equatable {
        let bindingId: String
        let deviceId: String
        let tag: String
        let platform: String
        let endpointId: String
        let identityGeneration: Int
    }

    let jti: String
    let iat: Int64
    let nbf: Int64
    let exp: Int64
    let alpn: String
    let scope: String
    let initiator: Peer
    let acceptor: Peer
}

enum DotGrantVerifier {
    private static let pairGrantLifetime: Int64 = 7 * 24 * 60 * 60
    private static let uuidPattern = try! NSRegularExpression(
        pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
        options: [.caseInsensitive]
    )

    static func verify(_ token: String, keys: [Data], now: Date = Date()) throws -> DotGrantClaims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              token.utf8.count <= 16_384,
              let header = decodeBase64URL(String(parts[0])),
              let payload = decodeBase64URL(String(parts[1])),
              let signature = decodeBase64URL(String(parts[2])),
              signature.count == 64,
              let object = try? JSONSerialization.jsonObject(with: header) as? [String: Any],
              object["alg"] as? String == "EdDSA",
              object["typ"] as? String == "cmux-pair-grant+jwt",
              let kid = object["kid"] as? String,
              !kid.isEmpty,
              kid.utf8.count <= 128,
              kid.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) ||
                  (byte >= 65 && byte <= 90) ||
                  (byte >= 97 && byte <= 122) ||
                  byte == 45 || byte == 46 || byte == 95
              }),
              object.keys.count == 3 else {
            throw DotTransportError.admissionFailed("invalid grant")
        }
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard keys.contains(where: { key in
            guard key.count == 32, let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key)
            else { return false }
            return publicKey.isValidSignature(signature, for: signingInput)
        }) else {
            throw DotTransportError.admissionFailed("invalid grant signature")
        }
        let claims: DotGrantClaims
        do {
            claims = try JSONDecoder().decode(DotGrantClaims.self, from: payload)
        } catch {
            throw DotTransportError.admissionFailed("invalid grant claims")
        }
        guard exactKeys(
            payload,
            allowed: ["jti", "iat", "nbf", "exp", "alpn", "scope", "initiator", "acceptor"]
        ),
        exactPeerKeys(payload, key: "initiator"),
        exactPeerKeys(payload, key: "acceptor"),
        validatePeer(claims.initiator, platform: "ios"),
        validatePeer(claims.acceptor, platform: "mac"),
        claims.initiator.bindingId != claims.acceptor.bindingId,
        claims.initiator.deviceId != claims.acceptor.deviceId,
        claims.initiator.endpointId.lowercased() != claims.acceptor.endpointId.lowercased(),
        isUUID(claims.jti),
        claims.iat >= 0,
        claims.nbf >= 0,
        claims.exp >= 0,
        claims.nbf >= claims.iat - 30 else {
            throw DotTransportError.admissionFailed("invalid grant claims")
        }
        let nowSeconds = Int64(now.timeIntervalSince1970.rounded(.down))
        guard claims.alpn == "cmux/mobile/1",
              claims.scope == "cmux.mobile.attach",
              claims.exp > claims.nbf,
              claims.exp > nowSeconds,
              claims.nbf <= nowSeconds + 30,
              claims.exp - claims.iat <= pairGrantLifetime,
              claims.iat <= nowSeconds + 30,
              claims.initiator.platform == "ios",
              claims.acceptor.platform == "mac" else {
            throw DotTransportError.admissionFailed("expired or invalid grant")
        }
        return claims
    }

    private static func exactKeys(_ data: Data, allowed: [String]) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value.keys.count == allowed.count else { return false }
        return Set(value.keys) == Set(allowed)
    }

    private static func validatePeer(_ peer: DotGrantClaims.Peer, platform: String) -> Bool {
        peer.platform == platform &&
        isUUID(peer.bindingId) &&
        isUUID(peer.deviceId) &&
        !peer.tag.isEmpty && peer.tag.utf8.count <= 64 &&
        peer.identityGeneration > 0 && peer.identityGeneration <= 2_147_483_647 &&
        peer.endpointId.count == 64 &&
        peer.endpointId.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) ||
            (byte >= 65 && byte <= 70) ||
            (byte >= 97 && byte <= 102)
        }
    }

    private static func exactPeerKeys(_ data: Data, key: String) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peer = value[key] as? [String: Any] else { return false }
        let allowed = ["bindingId", "deviceId", "tag", "platform", "endpointId", "identityGeneration"]
        return peer.keys.count == allowed.count && Set(peer.keys) == Set(allowed)
    }

    private static func isUUID(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return uuidPattern.firstMatch(in: value, options: [], range: range) != nil
    }

    static func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) })
        else { return nil }
        let padded = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { return nil }
        let canonical = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return canonical == value ? data : nil
    }
}

actor DotSecureSession: DotSecureSessionProtocol {
    enum Role { case phone, host }

    nonisolated let peer: DotAdmittedPeer
    nonisolated let sessionID: String
    nonisolated let events: AsyncStream<DotSessionEvent>

    private let role: Role
    private let leg: DotLeg
    private let destinationLegID: UInt32
    private let identity: any DotIdentitySigning
    private let admission: DotAdmissionMaterial
    private let judge: (@Sendable (DotAdmittedPeer) async throws -> Void)?
    private var continuation: AsyncStream<DotSessionEvent>.Continuation?
    private var key: SymmetricKey?
    /// Stream IDs are directional. The phone owns odd IDs and the host owns
    /// even IDs, so a host-opened lane can never collide with the phone's
    /// control stream (or any other phone-opened lane) in the shared mux.
    private var nextStreamID: UInt32
    private var streams: [UInt32: DotStreamImpl] = [:]
    private var closed = false
    private var handshakeWaiter: CheckedContinuation<Void, any Error>?
    private var handshakeComplete = false
    private var handshakeFailure: DotTransportError?
    private var clientNonce: Data?
    /// Retain the signed hello until the server answers. A phone can finish
    /// its relay hello before the Mac's host leg exists; the relay buffers
    /// that first upload, but a fresh host intentionally clears stale
    /// host-destined state. Re-sending on `peer.online` makes the phone-first
    /// ordering converge without replaying encrypted frames from a prior host
    /// process.
    private var clientHelloFrame: Data?
    private var remoteLegID: UInt32?

    private init(
        role: Role,
        leg: DotLeg,
        destinationLegID: UInt32,
        identity: any DotIdentitySigning,
        admission: DotAdmissionMaterial,
        peer: DotAdmittedPeer,
        sessionID: String,
        judge: (@Sendable (DotAdmittedPeer) async throws -> Void)?
    ) {
        self.role = role
        self.leg = leg
        self.destinationLegID = destinationLegID
        self.identity = identity
        self.admission = admission
        self.peer = peer
        self.sessionID = sessionID
        self.judge = judge
        self.nextStreamID = role == .phone ? 1 : 2
        let (stream, continuation) = AsyncStream.makeStream(of: DotSessionEvent.self)
        self.events = stream
        self.continuation = continuation
    }

    static func makeClient(
        leg: DotLeg,
        identity: any DotIdentitySigning,
        admission: DotAdmissionMaterial
    ) throws -> DotSecureSession {
        guard leg.configuration.role == .phone else {
            throw DotTransportError.admissionFailed("client leg has wrong role")
        }
        guard let grant = admission.grantJWS else {
            throw DotTransportError.admissionFailed("missing pair grant")
        }
        let claims = try DotGrantVerifier.verify(grant, keys: admission.grantVerificationKeys)
        guard identity.publicKey.count == 32,
              claims.initiator.endpointId.lowercased() == hex(identity.publicKey),
              let expected = admission.expectedPeerPublicKey,
              expected.count == 32,
              hex(expected) == claims.acceptor.endpointId.lowercased() else {
            throw DotTransportError.admissionFailed("grant peer mismatch")
        }
        let peer = DotAdmittedPeer(
            identityPublicKey: expected,
            deviceID: claims.acceptor.deviceId,
            platform: claims.acceptor.platform,
            tag: claims.acceptor.tag,
            bindingID: claims.acceptor.bindingId,
            grantJTI: claims.jti
        )
        let sessionID = UUID().uuidString
        return DotSecureSession(
            role: .phone,
            leg: leg,
            destinationLegID: 0,
            identity: identity,
            admission: admission,
            peer: peer,
            sessionID: sessionID,
            judge: nil
        )
    }

    static func makeServer(
        leg: DotLeg,
        destinationLegID: UInt32,
        identity: any DotIdentitySigning,
        admission: DotAdmissionMaterial,
        hello: DotClientHello,
        judge: @escaping @Sendable (DotAdmittedPeer) async throws -> Void
    ) async throws -> DotSecureSession {
        guard leg.configuration.role == .host,
              identity.publicKey.count == 32,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: hello.identity)) != nil else {
            throw DotTransportError.admissionFailed("invalid handshake identity")
        }
        let claims = try DotGrantVerifier.verify(hello.grant, keys: admission.grantVerificationKeys)
        guard hello.sessionID.count <= 128,
              hello.identity.count == 32,
              hello.ephemeral.count == 32,
              hello.nonce.count == 32,
              hello.signature.count == 64,
              hex(hello.identity) == claims.initiator.endpointId.lowercased(),
              claims.acceptor.deviceId == leg.configuration.macDeviceID,
              hex(identity.publicKey) == claims.acceptor.endpointId.lowercased() else {
            throw DotTransportError.admissionFailed("grant endpoint mismatch")
        }
        let peer = DotAdmittedPeer(
            identityPublicKey: hello.identity,
            deviceID: claims.initiator.deviceId,
            platform: claims.initiator.platform,
            tag: claims.initiator.tag,
            bindingID: claims.initiator.bindingId,
            grantJTI: claims.jti
        )
        let session = DotSecureSession(
            role: .host,
            leg: leg,
            destinationLegID: destinationLegID,
            identity: identity,
            admission: admission,
            peer: peer,
            sessionID: hello.sessionID,
            judge: judge
        )
        try await session.finishServerHandshake(hello: hello)
        return session
    }

    func beginClientHandshake() async throws {
        guard role == .phone, let grant = admission.grantJWS else {
            throw DotTransportError.admissionFailed("missing client grant")
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        clientEphemeral = ephemeral
        let nonce = Self.randomNonce()
        clientNonce = nonce
        let signature = try await identity.sign(Self.clientTranscript(
            sessionID: sessionID,
            identity: identity.publicKey,
            ephemeral: ephemeral.publicKey.rawRepresentation,
            nonce: nonce,
            grant: grant
        ))
        let hello = DotClientHello(
            sessionID: sessionID,
            identity: identity.publicKey,
            ephemeral: ephemeral.publicKey.rawRepresentation,
            nonce: nonce,
            grant: grant,
            signature: signature
        )
        let body = try JSONEncoder().encode(hello)
        let frame = try DotSessionFrame(kind: .clientHello, streamID: 0, sessionID: sessionID, body: body).encoded()
        clientHelloFrame = frame
        try await leg.send(frame, to: destinationLegID)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        Task { await self.setHandshakeWaiter(continuation) }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw DotTransportError.admissionFailed("handshake timeout")
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            handshakeFailure = (error as? DotTransportError)
                ?? .admissionFailed("handshake failed")
            handshakeWaiter?.resume(throwing: error)
            handshakeWaiter = nil
            throw error
        }
        clearHandshakeEphemeral()
    }

    private var clientEphemeral: Curve25519.KeyAgreement.PrivateKey?

    private func setHandshakeWaiter(_ waiter: CheckedContinuation<Void, any Error>) {
        if handshakeComplete {
            waiter.resume()
        } else if let handshakeFailure {
            waiter.resume(throwing: handshakeFailure)
        } else {
            handshakeWaiter = waiter
        }
    }

    private func clearHandshakeEphemeral() {
        clientEphemeral = nil
        clientNonce = nil
    }

    private func finishServerHandshake(hello: DotClientHello) async throws {
        let clientEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hello.ephemeral)
        let serverEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let transcript = Self.serverTranscript(
            sessionID: hello.sessionID,
            clientIdentity: hello.identity,
            clientEphemeral: hello.ephemeral,
            clientNonce: hello.nonce,
            serverIdentity: identity.publicKey,
            serverEphemeral: serverEphemeral.publicKey.rawRepresentation
        )
        guard let phoneSigning = try? Curve25519.Signing.PublicKey(rawRepresentation: hello.identity),
              phoneSigning.isValidSignature(hello.signature, for: Self.clientTranscript(
                sessionID: hello.sessionID,
                identity: hello.identity,
                ephemeral: hello.ephemeral,
                nonce: hello.nonce,
                grant: hello.grant
              )) else {
            throw DotTransportError.admissionFailed("invalid peer signature")
        }
        let shared = try serverEphemeral.sharedSecretFromKeyAgreement(with: clientEphemeral)
        key = Self.deriveKey(shared: shared, transcript: transcript)
        try await judge?(peer)
        let signature = try await identity.sign(transcript)
        let response = DotServerHello(
            sessionID: hello.sessionID,
            identity: identity.publicKey,
            ephemeral: serverEphemeral.publicKey.rawRepresentation,
            nonce: hello.nonce,
            signature: signature
        )
        let body = try JSONEncoder().encode(response)
        let frame = try DotSessionFrame(kind: .serverHello, streamID: 0, sessionID: sessionID, body: body).encoded()
        try await leg.send(frame, to: destinationLegID)
        handshakeComplete = true
    }

    func receiveFrame(sourceLegID: UInt32, payload: Data) async {
        guard !closed else { return }
        guard let frame = DotSessionFrame.decode(payload) else {
            await close(reason: "malformed session frame")
            return
        }
        guard frame.sessionID == sessionID else { return }
        let expectedSource = role == .host ? destinationLegID : await leg.legID
        guard let expectedSource, expectedSource == sourceLegID else {
            await close(reason: "unexpected source leg")
            return
        }
        switch frame.kind {
        case .clientHello, .serverHello:
            guard frame.streamID == 0 else {
                await close(reason: "handshake on data stream")
                return
            }
        case .open, .openAck, .data, .close:
            guard frame.streamID > 0 else {
                await close(reason: "data frame on control stream")
                return
            }
        }
        do {
            switch frame.kind {
            case .serverHello:
                try await finishClientHandshake(body: frame.body)
            case .open:
                try await receiveOpen(streamID: frame.streamID, body: frame.body)
            case .openAck:
                break
            case .data:
                try await receiveData(streamID: frame.streamID, body: frame.body)
            case .close:
                try await receiveClose(streamID: frame.streamID, body: frame.body)
            case .clientHello:
                break
            }
        } catch {
            await close(reason: String(describing: error))
        }
    }

    private func finishClientHandshake(body: Data) async throws {
        guard role == .phone, key == nil else { return }
        let hello = try JSONDecoder().decode(DotServerHello.self, from: body)
        guard let expected = admission.expectedPeerPublicKey,
              hello.sessionID == sessionID,
              hello.identity == expected,
              hello.identity.count == 32,
              hello.ephemeral.count == 32,
              hello.nonce.count == 32,
              hello.signature.count == 64,
              hello.nonce == clientNonce else {
            throw DotTransportError.admissionFailed("unexpected host identity")
        }
        let serverKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hello.ephemeral)
        // The client transcript is the same bytes the server signed. The
        // client identity and grant are already bound by the broker grant.
        let transcript = Self.serverTranscript(
            sessionID: hello.sessionID,
            clientIdentity: identity.publicKey,
            clientEphemeral: clientEphemeral?.publicKey.rawRepresentation ?? Data(),
            clientNonce: hello.nonce,
            serverIdentity: hello.identity,
            serverEphemeral: hello.ephemeral
        )
        guard let signer = try? Curve25519.Signing.PublicKey(rawRepresentation: hello.identity),
              signer.isValidSignature(hello.signature, for: transcript) else {
            throw DotTransportError.admissionFailed("invalid host signature")
        }
        guard let ephemeral = clientEphemeral else {
            throw DotTransportError.admissionFailed("missing client key")
        }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: serverKey)
        key = Self.deriveKey(shared: shared, transcript: transcript)
        handshakeComplete = true
        handshakeFailure = nil
        handshakeWaiter?.resume()
        handshakeWaiter = nil
    }

    func openStream(_ descriptor: DotLaneDescriptor) async throws -> any DotStream {
        guard key != nil, !closed else { throw DotTransportError.sessionEnded("session closed") }
        let id = nextStreamID
        guard id > 0 else { throw DotTransportError.protocolViolation("stream id exhausted") }
        nextStreamID = id <= UInt32.max - 2 ? id + 2 : 0
        let stream = DotStreamImpl(id: id, descriptor: descriptor, session: self)
        streams[id] = stream
        let body = try JSONEncoder().encode(DotOpenMessage(descriptor: descriptor))
        let frame = try DotSessionFrame(kind: .open, streamID: id, sessionID: sessionID, body: body).encoded()
        try await leg.send(frame, to: destinationLegID)
        return stream
    }

    /// A peer.online carrying a different relay leg means the remote process
    /// started a fresh session. Resumed legs keep the same id and therefore do
    /// not disturb the encrypted mux.
    func observePeerOnline(legID: UInt32?) async {
        guard role == .phone, let legID else { return }
        if let remoteLegID, remoteLegID != legID {
            await close(reason: "peer session replaced")
            return
        }
        if remoteLegID == nil, !handshakeComplete, let clientHelloFrame {
            // The host joined after this phone leg. Its fresh host leg dropped
            // any buffered hello from before startup, so send a new sequenced
            // copy to the now-live host.
            try? await leg.send(clientHelloFrame, to: 0)
        }
        remoteLegID = legID
    }

    func sendStreamData(id: UInt32, data: Data) async throws {
        guard let key, !closed else { throw DotTransportError.sessionEnded("session closed") }
        let sealed = try ChaChaPoly.seal(data, using: key).combined
        let frame = try DotSessionFrame(kind: .data, streamID: id, sessionID: sessionID, body: sealed).encoded()
        try await leg.send(frame, to: destinationLegID)
    }

    func closeStreamWrite(id: UInt32) async {
        guard !closed else { return }
        let body = (try? JSONEncoder().encode(DotCloseMessage(writeOnly: true))) ?? Data()
        if let frame = try? DotSessionFrame(kind: .close, streamID: id, sessionID: sessionID, body: body).encoded() {
            try? await leg.send(frame, to: destinationLegID)
        }
    }

    func closeStream(id: UInt32) async {
        guard !closed else { return }
        streams[id] = nil
        let body = (try? JSONEncoder().encode(DotCloseMessage(writeOnly: false))) ?? Data()
        if let frame = try? DotSessionFrame(kind: .close, streamID: id, sessionID: sessionID, body: body).encoded() {
            try? await leg.send(frame, to: destinationLegID)
        }
    }

    private func receiveOpen(streamID: UInt32, body: Data) async throws {
        guard key != nil else { return }
        // An inbound OPEN must come from the peer's half of the directional
        // namespace. Treat a reused local ID as a protocol error instead of
        // silently dropping the lane and leaving its consumer hung.
        let localParity = role == .phone ? UInt32(1) : UInt32(0)
        guard streamID & 1 != localParity,
              streams[streamID] == nil else {
            throw DotTransportError.protocolViolation("invalid peer stream id")
        }
        let open = try JSONDecoder().decode(DotOpenMessage.self, from: body)
        let stream = DotStreamImpl(id: streamID, descriptor: open.descriptor, session: self)
        streams[streamID] = stream
        let ackBody = try JSONEncoder().encode(DotOpenAckMessage(accepted: true, reason: nil))
        let ack = try DotSessionFrame(kind: .openAck, streamID: streamID, sessionID: sessionID, body: ackBody).encoded()
        try await leg.send(ack, to: destinationLegID)
        continuation?.yield(.inboundStream(stream))
    }

    private func receiveData(streamID: UInt32, body: Data) async throws {
        guard let key, let stream = streams[streamID] else { return }
        let sealed = try ChaChaPoly.SealedBox(combined: body)
        let plaintext = try ChaChaPoly.open(sealed, using: key)
        await stream.receive(plaintext)
    }

    private func receiveClose(streamID: UInt32, body: Data) async throws {
        guard let stream = streams[streamID] else { return }
        await stream.finishInbound()
        let close = try JSONDecoder().decode(DotCloseMessage.self, from: body)
        if !close.writeOnly { streams[streamID] = nil }
    }

    func close(reason: String) async {
        guard !closed else { return }
        closed = true
        handshakeFailure = .sessionEnded(reason)
        handshakeWaiter?.resume(throwing: DotTransportError.sessionEnded(reason))
        handshakeWaiter = nil
        for stream in streams.values { await stream.finishInbound() }
        streams.removeAll()
        continuation?.yield(.ended(reason: reason))
        continuation?.finish()
        continuation = nil
        if role == .phone {
            await leg.stop()
        }
    }

    private static func clientTranscript(
        sessionID: String,
        identity: Data,
        ephemeral: Data,
        nonce: Data,
        grant: String
    ) -> Data {
        Data("dot/client/1|\(sessionID)|\(identity.base64EncodedString())|\(ephemeral.base64EncodedString())|\(nonce.base64EncodedString())|\(grant)".utf8)
    }

    private static func serverTranscript(
        sessionID: String,
        clientIdentity: Data,
        clientEphemeral: Data,
        clientNonce: Data,
        serverIdentity: Data,
        serverEphemeral: Data
    ) -> Data {
        Data("dot/server/1|\(sessionID)|\(clientIdentity.base64EncodedString())|\(clientEphemeral.base64EncodedString())|\(clientNonce.base64EncodedString())|\(serverIdentity.base64EncodedString())|\(serverEphemeral.base64EncodedString())".utf8)
    }

    private static func deriveKey(shared: SharedSecret, transcript: Data) -> SymmetricKey {
        let digest = SHA256.hash(data: transcript)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(digest),
            sharedInfo: Data("cmux-dot-session-v1".utf8),
            outputByteCount: 32
        )
    }

    private static func randomNonce() -> Data {
        var bytes = Data(count: 32)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            for offset in 0..<buffer.count { base.storeBytes(of: UInt8.random(in: 0...255), toByteOffset: offset, as: UInt8.self) }
        }
        return bytes
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Engine and acceptor implementations

extension DotPeerEngine {
    func establish() async throws -> any DotSecureSessionProtocol {
        configuration.leg.journal.record(component: "session", event: "establish-start")
        let leg = DotLeg(configuration: configuration.leg)
        let session: DotSecureSession
        do {
            session = try DotSecureSession.makeClient(
                leg: leg,
                identity: configuration.identity,
                admission: configuration.admission
            )
        } catch {
            configuration.leg.journal.record(
                component: "session", event: "client-build-failed",
                attributes: ["error": String(describing: error)]
            )
            throw error
        }
        let events = await leg.start()
        pumpTask = Task { [weak self, weak leg] in
            for await event in events {
                guard let self else { return }
                await self.handle(event: event, session: session)
            }
            await session.close(reason: "leg ended")
            _ = leg
        }
        do {
            try await session.beginClientHandshake()
        } catch {
            configuration.leg.journal.record(
                component: "session", event: "handshake-failed",
                attributes: ["error": String(describing: error)]
            )
            await session.close(reason: "handshake failed")
            await leg.stop()
            pumpTask?.cancel()
            pumpTask = nil
            throw error
        }
        configuration.leg.journal.record(component: "session", event: "handshake-complete")
        return session
    }

    func handle(event: DotLegEvent, session: DotSecureSession) async {
        switch event {
        case let .frame(source, payload): await session.receiveFrame(sourceLegID: source, payload: payload)
        case let .peerOnline(id, _): await session.observePeerOnline(legID: id)
        case let .reset(reason): await end(session: session, reason: reason)
        case let .closed(reason): await end(session: session, reason: reason)
        default: break
        }
    }

    private func end(session: DotSecureSession, reason: String) async {
        await session.close(reason: reason)
        if currentSession?.sessionID == session.sessionID {
            currentSession = nil
            if !stopped { setState(.closed(reason: reason)) }
        }
    }
}

extension DotSessionAcceptor {
    func runLoop() async {
        configuration.leg.journal.record(
            component: "acceptor", event: "run-loop-started",
            attributes: ["role": configuration.leg.role.rawValue]
        )
        let leg = DotLeg(configuration: configuration.leg)
        self.leg = leg
        configuration.leg.journal.record(
            component: "acceptor", event: "leg-starting",
            attributes: ["role": configuration.leg.role.rawValue]
        )
        let events = await leg.start()
        configuration.leg.journal.record(
            component: "acceptor", event: "leg-started",
            attributes: ["role": configuration.leg.role.rawValue]
        )
        for await event in events {
            guard !stopped else { return }
            switch event {
            case let .frame(sourceLegID, payload):
                await handleFrame(sourceLegID: sourceLegID, payload: payload, leg: leg)
            case .up, .resumed:
                continuation?.yield(.legEvent(event))
            case let .suspended(reason): continuation?.yield(.legEvent(.suspended(reason: reason)))
            case let .reset(reason): continuation?.yield(.legEvent(.reset(reason: reason)))
            case let .peerOnline(id, device):
                // peer.online is emitted only when a side creates a fresh
                // leg. A resumable network drop is intentionally silent.
                if let device {
                    let old = sessions.filter { $0.value.peer.deviceID == device }
                    for (sessionID, session) in old {
                        await session.close(reason: "peer session replaced")
                        sessions[sessionID] = nil
                    }
                }
                continuation?.yield(.legEvent(.peerOnline(legID: id, device: device)))
            case let .peerOffline(id, reason): continuation?.yield(.legEvent(.peerOffline(legID: id, reason: reason)))
            case let .closed(reason): continuation?.yield(.legEvent(.closed(reason: reason)))
            }
        }
    }

    func handleFrame(sourceLegID: UInt32, payload: Data, leg: DotLeg) async {
        guard let frame = DotSessionFrame.decode(payload) else {
            configuration.leg.journal.record(
                component: "acceptor", event: "frame-rejected",
                attributes: ["source_leg": String(sourceLegID), "reason": "malformed-session-frame"]
            )
            return
        }
        configuration.leg.journal.record(
            component: "acceptor", event: "frame-received",
            attributes: [
                "source_leg": String(sourceLegID),
                "kind": String(frame.kind.rawValue),
                "session": frame.sessionID,
            ]
        )
        if let session = sessions[frame.sessionID] {
            await session.receiveFrame(sourceLegID: sourceLegID, payload: payload)
            return
        }
        guard frame.kind == .clientHello,
              let hello = try? JSONDecoder().decode(DotClientHello.self, from: frame.body) else {
            configuration.leg.journal.record(
                component: "acceptor", event: "frame-rejected",
                attributes: ["source_leg": String(sourceLegID), "reason": "unexpected-session-frame"]
            )
            continuation?.yield(.denied(deviceID: nil, reason: "malformed hello"))
            return
        }
        do {
            let session = try await DotSecureSession.makeServer(
                leg: leg,
                destinationLegID: sourceLegID,
                identity: configuration.identity,
                admission: configuration.admission,
                hello: hello,
                judge: configuration.judge
            )
            // A fresh phone leg supersedes any older session for that device.
            // Resume reconnects never send a new client hello, so this does
            // not interrupt the no-disconnect path.
            let old = sessions.filter { $0.value.peer.deviceID == session.peer.deviceID }
            for (sessionID, existing) in old {
                await existing.close(reason: "peer session replaced")
                sessions[sessionID] = nil
            }
            sessions[hello.sessionID] = session
            continuation?.yield(.admitted(session))
        } catch {
            configuration.leg.journal.record(
                component: "acceptor", event: "admission-failed",
                attributes: ["source_leg": String(sourceLegID), "error": String(describing: error)]
            )
            continuation?.yield(.denied(deviceID: nil, reason: String(describing: error)))
        }
    }
}
