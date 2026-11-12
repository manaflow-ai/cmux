import Foundation

/// One Cloud machine's carrier session, as the Rust `CloudCarrier` serves it: dialed with the
/// person's own access token and this phone's Noise key, pinned to the machine's daemon key,
/// carrying `cmux.protocol/2` line streams. A protocol so the link is tested without the FFI.
public protocol CloudCarrierSession: AnyObject, Sendable {
    /// Dials the machine unless a live session is up, within `deadlineMs`.
    func connect(deadlineMs: UInt32) async throws
    /// One more daemon line stream; `LinkError` `closed` when no session is up (connect again).
    func openStream() async throws -> any CloudCarrierByteStream
    /// The token the next resume or dial asks the platform with.
    func setAccessToken(_ accessToken: String)
    func isConnected() async -> Bool
    func close() async
}

/// One daemon line stream on a carrier: bytes are an arbitrary split of protocol lines.
public protocol CloudCarrierByteStream: AnyObject, Sendable {
    func send(_ data: Data) async throws
    /// The next bytes, or nil once the stream ended.
    func recv() async -> Data?
    func close() async
}

/// A Cloud machine as a ``MacLink``: its carrier serves the `daemon` service only (the
/// machine's cmux-tui), so workspaces, terminals (and the whole sizing protocol), rename,
/// close and creation run on it exactly as on a Mac. Every other service (`auth`, `acpmux`,
/// `version`, `file`, `upload`, `browser`, `chief`, …) is refused with `unknown_service`
/// without touching the network: deny by default.
public final class CloudCarrierLink: MacLink, @unchecked Sendable { // crash-allow: lock-guarded state, immutable rest
    public let transport: TransportKind = .cloudCarrier
    public let states: AsyncStream<LinkState>
    public let machineID: String
    private let continuation: AsyncStream<LinkState>.Continuation
    private let session: any CloudCarrierSession
    private let accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
    private let lock = NSLock()
    private var nextChannel: UInt32 = 1
    private var closed = false

    /// The one service a Cloud machine's carrier serves.
    public static let service = "daemon"
    /// How long a reconnect inside `openChannel` may take.
    public static let reconnectDeadlineMillis: UInt32 = 20_000

    public init(machineID: String, session: any CloudCarrierSession,
                accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String) {
        self.machineID = machineID
        self.session = session
        self.accessToken = accessToken
        (states, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        continuation.yield(.connected(.cloudCarrier, .carrier, rttMillis: nil))
    }

    public var connectedPath: LinkPathKind? { .carrier }

    public func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        guard service == Self.service else {
            throw LinkError(code: "unknown_service", message: "Cloud machines don't serve \(service) to this iPhone")
        }
        guard !lock.withLock({ closed }) else { throw LinkError(code: "closed", message: "the Cloud link closed") }
        let stream = try await openStream()
        let id = lock.withLock { () -> UInt32 in
            defer { nextChannel += 2 }
            return nextChannel
        }
        return CloudCarrierChannel(id: id, stream: stream)
    }

    /// The carrier has one lane: input rides an ordinary stream.
    public func openInputChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        try await openChannel(service: service, args: args)
    }

    /// A stream on the live session; a session that ended is dialed again first (with a fresh
    /// token, and one forced refresh when the platform refuses it as expired).
    private func openStream() async throws -> any CloudCarrierByteStream {
        do {
            return try await session.openStream()
        } catch let error as LinkError where error.code == "closed" {
            try await reconnect()
            return try await session.openStream()
        }
    }

    private func reconnect() async throws {
        session.setAccessToken(try await accessToken(false))
        do {
            try await session.connect(deadlineMs: Self.reconnectDeadlineMillis)
        } catch let error as LinkError where error.code == LinkError.unauthorized {
            session.setAccessToken(try await accessToken(true))
            do {
                try await session.connect(deadlineMs: Self.reconnectDeadlineMillis)
            } catch {
                dropped(error)
                throw error
            }
        } catch {
            if !CloudCarrierDialer.isRetryable(error) { dropped(error) }
            throw error
        }
    }

    private func dropped(_ error: any Error) {
        let reason = (error as? LinkError).map { $0.message.isEmpty ? $0.code : $0.message } ?? "the Cloud link dropped"
        continuation.yield(.disconnected(reason: reason))
    }

    /// Liveness without a round trip: whether the carrier's session is still up (the Rust
    /// session closes itself when the relay or the Noise session ends). A dead one fails the
    /// heartbeat, so the controller redials it.
    public func ping() async throws -> UInt32 {
        guard await session.isConnected() else { throw LinkError(code: "closed", message: "the Cloud link dropped") }
        return 0
    }

    public func probe(timeout: Duration) async throws -> UInt32? {
        try await ping()
    }

    /// A new token for the session's next resume (the coordinator refreshes it before expiry).
    public func setAccessToken(_ token: String) {
        session.setAccessToken(token)
    }

    public func close() async {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        await session.close()
        continuation.yield(.disconnected(reason: "closed"))
        continuation.finish()
    }
}

/// One `daemon` stream on a carrier, as a link channel.
final class CloudCarrierChannel: LinkChannel, @unchecked Sendable { // crash-allow: immutable after init
    let id: UInt32
    private let stream: any CloudCarrierByteStream

    init(id: UInt32, stream: any CloudCarrierByteStream) {
        self.id = id
        self.stream = stream
    }

    func send(_ data: Data) async throws {
        try await stream.send(data)
    }

    func receive() async throws -> Data? {
        await stream.recv()
    }

    func close(code: String, reason: String) async {
        await stream.close()
    }
}

/// Dials Cloud machines: `endpoint.macDeviceID` is the machine id (`vm_…`). Each dial makes a
/// new carrier session (the controller closes the old link first), connects it, and hands
/// back a ``CloudCarrierLink`` serving `daemon` only.
public struct CloudCarrierDialer: MacLinkDialer {
    /// Makes a carrier session for a machine with the dial's token.
    public typealias MakeSession = @Sendable (_ machineID: String, _ accessToken: String) throws -> any CloudCarrierSession

    private let makeSession: MakeSession
    private let accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
    /// How long a dial may take (the platform grant, the relay slot and the Noise handshake).
    public var deadlineMillis: UInt32 = 25_000

    public init(makeSession: @escaping MakeSession, accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String) {
        self.makeSession = makeSession
        self.accessToken = accessToken
    }

    public func dial(_ endpoint: LinkEndpoint, transport: TransportKind, accessToken token: String) async throws -> any MacLink {
        let machineID = endpoint.macDeviceID
        guard machineID.hasPrefix("vm_") else {
            throw LinkError(code: "invalid_argument", message: "not a Cloud machine")
        }
        let session = try makeSession(machineID, token)
        do {
            try await session.connect(deadlineMs: deadlineMillis)
        } catch {
            await session.close()
            throw error
        }
        return CloudCarrierLink(machineID: machineID, session: session, accessToken: accessToken)
    }

    /// Refusals no redial can fix until something changes: the daemon is not the pinned one or
    /// refused this phone's grant, the machine is paused or gone, the account may not use it,
    /// or Cloud is turned off. The coordinator stops dialing and shows why.
    public static let permanentCodes: Set<String> = [
        "carrier.handshake", "cloud.machine.paused", "cloud.machine.not_found", "auth.forbidden", "feature.disabled",
        "invalid_argument",
    ]

    /// Whether a redial may help (`transport`, a timeout, a session that ended).
    public static func isRetryable(_ error: any Error) -> Bool {
        guard let error = error as? LinkError else { return true }
        return !permanentCodes.contains(error.code) && error.code != LinkError.unauthorized
    }

    /// Whether `error` is a refusal no redial fixes (``permanentCodes``).
    public static func isPermanent(_ error: any Error) -> Bool {
        (error as? LinkError).map { permanentCodes.contains($0.code) } ?? false
    }
}

#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI

extension CloudCarrierDialer {
    /// The Rust carrier: `apiBase` the Cloud API, `teamID` the team the Cloud Machines page
    /// reads (`x-cmux-team`; nil: the account's default), the phone's Noise key from the Keychain.
    public static func ffi(apiBase: URL, teamID: String?, deviceName: String,
                           noiseKey: @escaping @Sendable () throws -> Data,
                           accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String) -> CloudCarrierDialer {
        CloudCarrierDialer(makeSession: { machineID, token in
            do {
                let carrier = try CloudCarrier(apiBase: apiBase.absoluteString, teamId: teamID, machineId: machineID,
                                               accessToken: token, noisePrivateKey: try noiseKey(), deviceName: deviceName)
                return FFICloudCarrierSession(carrier: carrier)
            } catch let error as CmuxMobileError {
                throw error.linkError
            }
        }, accessToken: accessToken)
    }

    /// A new 32-byte Noise private key for this phone's carriers.
    public static func newNoiseKey() throws -> Data {
        do { return try cloudCarrierNewKey() } catch let error as CmuxMobileError { throw error.linkError }
    }
}

final class FFICloudCarrierSession: CloudCarrierSession, @unchecked Sendable { // crash-allow: immutable after init
    private let carrier: CloudCarrier

    init(carrier: CloudCarrier) { self.carrier = carrier }

    func connect(deadlineMs: UInt32) async throws {
        do { try await carrier.connect(deadlineMs: deadlineMs) } catch let error as CmuxMobileError { throw error.linkError }
    }

    func openStream() async throws -> any CloudCarrierByteStream {
        do { return FFICloudCarrierStream(stream: try await carrier.openStream()) } catch let error as CmuxMobileError {
            throw error.linkError
        }
    }

    func setAccessToken(_ accessToken: String) { carrier.setAccessToken(accessToken: accessToken) }
    func isConnected() async -> Bool { await carrier.isConnected() }
    func close() async { await carrier.close() }
}

final class FFICloudCarrierStream: CloudCarrierByteStream, @unchecked Sendable { // crash-allow: immutable after init
    private let stream: CloudCarrierStream

    init(stream: CloudCarrierStream) { self.stream = stream }

    func send(_ data: Data) async throws {
        do { try await stream.send(data: data) } catch let error as CmuxMobileError { throw error.linkError }
    }

    func recv() async -> Data? { await stream.recv() }
    func close() async { await stream.close() }
}
#endif
