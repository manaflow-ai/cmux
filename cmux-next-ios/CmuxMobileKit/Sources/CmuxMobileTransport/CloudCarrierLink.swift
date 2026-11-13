import Foundation

/// One Cloud machine's carrier session, as the Rust `CloudCarrier` serves it: dialed with the
/// person's own access token and this phone's Noise key, pinned to the machine's daemon key,
/// carrying `cmux.protocol/2` line streams. A protocol so the link is tested without the FFI.
public protocol CloudCarrierSession: AnyObject, Sendable {
    /// Dials the machine unless a live session is up, within `deadlineMs`.
    func connect(deadlineMs: UInt32) async throws
    /// One more daemon line stream; `LinkError` `closed` when no session is up (connect again).
    func openStream() async throws -> any CloudCarrierByteStream
    func isConnected() async -> Bool
    /// Resolves once the live session ends or the carrier closes (at once without a session).
    func waitClosed() async
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
///
/// A link is one carrier session. It never dials again by itself: when the session ends
/// (the Rust carrier says so at once through `waitClosed`, or a stream finds it closed) the
/// link reports `disconnected`, and the controller dials a new link, on which the coordinator
/// binds the workspace list and terminals again. A link that reconnected inside itself would
/// keep reading "connected" while those stayed on the dead session's channels.
public final class CloudCarrierLink: MacLink, @unchecked Sendable { // crash-allow: lock-guarded state, immutable rest
    public let transport: TransportKind = .cloudCarrier
    public let states: AsyncStream<LinkState>
    public let machineID: String
    private let continuation: AsyncStream<LinkState>.Continuation
    private let session: any CloudCarrierSession
    private let lock = NSLock()
    private var nextChannel: UInt32 = 1
    private var closed = false

    /// The one service a Cloud machine's carrier serves.
    public static let service = "daemon"
    static let droppedReason = "the Cloud link dropped"

    public init(machineID: String, session: any CloudCarrierSession) {
        self.machineID = machineID
        self.session = session
        let (states, continuation) = AsyncStream<LinkState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.states = states
        self.continuation = continuation
        continuation.yield(.connected(.cloudCarrier, .carrier, rttMillis: nil))
        // The session's end, as soon as the carrier knows it (not at the next heartbeat).
        // task-owner: ends with the session (close resolves it too)
        Task.detached { [session] in
            await session.waitClosed()
            continuation.yield(.disconnected(reason: CloudCarrierLink.droppedReason))
        }
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

    /// A stream on the live session. A session that ended drops the link: the controller dials
    /// a new one (never a quiet reconnect under the same link).
    private func openStream() async throws -> any CloudCarrierByteStream {
        do {
            return try await session.openStream()
        } catch let error as LinkError where error.code == "closed" {
            continuation.yield(.disconnected(reason: Self.droppedReason))
            throw error
        }
    }

    /// Liveness without a round trip: whether the carrier's session is still up (the Rust
    /// session closes itself when the relay or the Noise session ends). A dead one fails the
    /// heartbeat, so the controller redials it.
    public func ping() async throws -> UInt32 {
        guard await session.isConnected() else { throw LinkError(code: "closed", message: Self.droppedReason) }
        return 0
    }

    public func probe(timeout: Duration) async throws -> UInt32? {
        try await ping()
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
    /// How long a dial may take (the platform grant, the relay slot and the Noise handshake).
    public var deadlineMillis: UInt32 = 25_000

    /// Each dial gets a fresh token from the controller (refreshed once after `unauthorized`).
    public init(makeSession: @escaping MakeSession) {
        self.makeSession = makeSession
    }

    public func dial(_ endpoint: LinkEndpoint, transport: TransportKind, accessToken token: String) async throws -> any MacLink {
        let machineID = endpoint.macDeviceID
        guard machineID.hasPrefix("vm_") else {
            throw LinkError(code: "invalid_argument", message: "not a Cloud machine")
        }
        let session = try makeSession(machineID, token)
        let deadline = deadlineMillis
        do {
            // A dial its caller stops waiting for (the controller cancels it: the link is no longer
            // wanted, the app went to the background) closes its session at once: the carrier's
            // close is final and cuts its dial short (the Rust dial does not see Swift's
            // cancellation through the generated async glue), so it asks for no more grants.
            try await withTaskCancellationHandler {
                try await session.connect(deadlineMs: deadline)
            } onCancel: {
                // task-owner: one close of this dial's own session
                Task.detached { await session.close() }
            }
            try Task.checkCancellation()
        } catch {
            await session.close()
            throw error
        }
        return CloudCarrierLink(machineID: machineID, session: session)
    }

    /// What a redial may fix: the network or relay (`transport`, `timeout`), a session that ended
    /// (`closed`), a malformed platform answer and a locked Keychain. Every other code a dial
    /// throws is a refusal no redial fixes until something changes (``isPermanent``): the carrier
    /// sends a retryable platform refusal (408, 429, 5xx, `owner.unreachable`) as `transport`, and
    /// a failure it gave up on as `carrier.failed`, so an unknown code never redials, and never
    /// asks the platform for grants, forever.
    public static let retryableCodes: Set<String> = ["transport", "timeout", "closed", "signaling", answerCode, keychainLocked]

    /// Codes the app words itself; any other refusal is shown with the carrier's message.
    public static let knownPermanentCodes: Set<String> = [
        "carrier.handshake", "carrier.failed", "cloud.machine.paused", "cloud.machine.not_found", "auth.forbidden",
        "feature.disabled", "invalid_argument", noDaemonKey, keychainUnavailable,
    ]

    /// A malformed platform answer (`cmux_mobile_carrier`): retryable.
    public static let answerCode = "carrier.answer"
    /// The Keychain is locked (before the first unlock): retryable.
    public static let keychainLocked = "keychain.locked"
    /// The Keychain can't be used at all (a missing entitlement, another error): no redial helps.
    public static let keychainUnavailable = "keychain.unavailable"

    /// The platform names no daemon key for the machine yet (`cmux_mobile_carrier::NO_DAEMON_KEY`):
    /// the carrier asked again inside its dial; the app waits for its machine list to change.
    public static let noDaemonKey = "carrier.no_daemon_key"

    /// Whether a redial may help (``retryableCodes``; an error that is not a `LinkError` too).
    public static func isRetryable(_ error: any Error) -> Bool {
        guard let error = error as? LinkError else { return true }
        return retryableCodes.contains(error.code)
    }

    /// Whether `error` is a refusal no redial fixes: any `LinkError` code outside
    /// ``retryableCodes`` but `unauthorized` (the sign-in path owns that one).
    public static func isPermanent(_ error: any Error) -> Bool {
        guard let error = error as? LinkError else { return false }
        return !retryableCodes.contains(error.code) && error.code != LinkError.unauthorized
    }
}

#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI

extension CloudCarrierDialer {
    /// The Rust carrier: `apiBase` the Cloud API, `teamID` the team the Cloud Machines page
    /// reads (`x-cmux-team`; nil: the account's default), the phone's Noise key from the Keychain,
    /// and the app's sign-in, which the carrier asks at every platform ask (a grant for a dial, a
    /// ticket for a resume), so a session that outlives one token resumes with the next.
    public static func ffi(apiBase: URL, teamID: String?, deviceName: String,
                           accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String,
                           noiseKey: @escaping @Sendable () throws -> Data) -> CloudCarrierDialer {
        let tokens = AppCloudTokens(accessToken: accessToken)
        return CloudCarrierDialer(makeSession: { machineID, _ in
            do {
                let carrier = try CloudCarrier(apiBase: apiBase.absoluteString, teamId: teamID, machineId: machineID,
                                               tokens: tokens, noisePrivateKey: try noiseKey(), deviceName: deviceName)
                return FFICloudCarrierSession(carrier: carrier)
            } catch let error as CmuxMobileError {
                throw error.linkError
            }
        })
    }

    /// A new 32-byte Noise private key for this phone's carriers.
    public static func newNoiseKey() throws -> Data {
        do { return try cloudCarrierNewKey() } catch let error as CmuxMobileError { throw error.linkError }
    }
}

/// The app's sign-in as the carrier's token source. A refused or missing sign-in is
/// `unauthorized`, so the carrier stops asking and the link reports it.
final class AppCloudTokens: CloudTokenSource, @unchecked Sendable { // crash-allow: immutable after init
    private let accessToken: @Sendable (Bool) async throws -> String

    init(accessToken: @escaping @Sendable (Bool) async throws -> String) { self.accessToken = accessToken }

    func accessToken(forceRefresh: Bool) async throws -> String {
        do {
            return try await accessToken(forceRefresh)
        } catch let error as LinkError where error.code == LinkError.unauthorized {
            throw CmuxMobileError.Refused(code: LinkError.unauthorized, message: error.message)
        } catch {
            throw CmuxMobileError.Transport(message: String(describing: error))
        }
    }
}

final class FFICloudCarrierSession: CloudCarrierSession, @unchecked Sendable { // crash-allow: immutable after init
    private let carrier: CloudCarrier

    init(carrier: CloudCarrier) { self.carrier = carrier }

    /// Cancellation is the dialer's: it closes this carrier when its caller stops waiting
    /// (``CloudCarrierDialer/dial(_:transport:accessToken:)``).
    func connect(deadlineMs: UInt32) async throws {
        do { try await carrier.connect(deadlineMs: deadlineMs) } catch let error as CmuxMobileError { throw error.linkError }
    }

    func openStream() async throws -> any CloudCarrierByteStream {
        do { return FFICloudCarrierStream(stream: try await carrier.openStream()) } catch let error as CmuxMobileError {
            throw error.linkError
        }
    }

    func isConnected() async -> Bool { await carrier.isConnected() }
    func waitClosed() async { await carrier.waitClosed() }
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
