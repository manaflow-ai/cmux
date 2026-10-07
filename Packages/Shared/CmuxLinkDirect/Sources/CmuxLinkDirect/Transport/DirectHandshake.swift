import CmuxLink
import Foundation

/// The Noise IK handshake over a started socket (b4-direct.md section 3).
struct DirectHandshake: Sendable {
    let identity: DirectIdentity

    /// Dialer side: proves `identity`, requires the host to hold `hostKey`.
    func dial(
        socket: DirectSocket, hostID: String, hostKey: DirectPublicKey, path: LinkPath, injector: DirectFaultInjector?
    ) async throws -> DirectTransport {
        var initiator = NoiseInitiator(
            staticKey: identity.privateKey, remoteStatic: hostKey, prologue: DirectHandshakePayload.prologue
        )
        let clock = ContinuousClock()
        let started = clock.now
        try await socket.send(record: try initiator.writeMessage1(payload: DirectHandshakePayload(hostID: hostID).encoded()))
        let reply: Data
        do {
            reply = try await socket.receiveRecord(maxLength: NoiseCipherState.maxMessageLength)
        } catch DirectSocketError.endOfStream {
            throw DirectCarrierError.handshakeRefused
        }
        let (payload, ciphers) = try initiator.readMessage2(reply)
        _ = try DirectHandshakePayload(decoding: payload, expectsHostID: false)
        return DirectTransport(
            socket: socket, ciphers: ciphers, path: path, remoteKey: hostKey,
            handshakeRTT: clock.now - started, injector: injector
        )
    }

    /// Host side: authenticates the device, checks it dialed this host, asks
    /// the authorizer, and answers only when allowed.
    func accept(
        socket: DirectSocket, hostID: String, authorizer: any DirectAuthorizer, path: LinkPath, injector: DirectFaultInjector?
    ) async throws -> DirectTransport {
        var responder = NoiseResponder(staticKey: identity.privateKey, prologue: DirectHandshakePayload.prologue)
        let first = try await socket.receiveRecord(maxLength: NoiseCipherState.maxMessageLength)
        let (deviceKey, payload) = try responder.readMessage1(first)
        let hello = try DirectHandshakePayload(decoding: payload, expectsHostID: true)
        guard hello.hostID == hostID else { throw DirectWireError.wrongHost }
        guard await authorizer.authorize(device: deviceKey) else { throw DirectAcceptError.unauthorized(deviceKey) }
        let (reply, ciphers) = try responder.writeMessage2(payload: DirectHandshakePayload(hostID: nil).encoded())
        try await socket.send(record: reply)
        return DirectTransport(
            socket: socket, ciphers: ciphers, path: path, remoteKey: deviceKey, handshakeRTT: nil, injector: injector
        )
    }
}
