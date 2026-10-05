import CmuxIrxTransport
import Foundation

/// A failure reported by the per-user account directory service.
enum AccountMacDirectoryFailure: Error, Equatable, Sendable {
    /// An `error.v1` frame or response with the Worker's stable code.
    case server(code: String, retryAfter: TimeInterval?)
    /// The frame did not match the account wire contract.
    case invalidFrame
}

/// Keeps this Mac listed in, and reads, the same Stack user's cross-team Mac
/// directory (`/v2/account/socket`).
///
/// It borrows the team control service's ticket and device descriptor; it
/// never authenticates on its own. A Worker that predates the route answers
/// 404, which marks the service unsupported and leaves discovery and admission
/// on the team directory alone until a long backoff retries.
actor AccountMacDirectoryClient {
    /// What one account socket authenticates with: the team ticket and the
    /// exact descriptor the ticket's claims name.
    struct Credentials: Equatable, Sendable {
        let device: V2DeviceDescriptor
        let ticket: V2Ticket

        /// Facts that require a new socket when they change. Other metadata,
        /// such as a relay hint, reaches the directory through the team record.
        fileprivate var connectionKey: [String] {
            [ticket.token, device.endpointID, String(device.identityGeneration),
             device.identity.teamID, device.identity.userID, device.identity.deviceID,
             device.identity.buildTag, device.identity.appNamespace,
             device.identity.environment, device.identity.projectID]
                + device.metadata.capabilities.sorted()
        }
    }

    /// External effects, injectable for tests.
    struct Dependencies: Sendable {
        let connect: @Sendable (URLRequest) async throws -> any V2ControlSocket
        let http: @Sendable (URLRequest) async throws -> V2HTTPResponse
        let sign: @Sendable (Data) async throws -> Data
        /// Signs the withdrawal. It runs after the account scope has already
        /// moved (a team switch), so it must not require the current scope:
        /// it only proves possession of the old endpoint key.
        let signWithdrawal: @Sendable (Data) async throws -> Data
        let now: @Sendable () -> Date
        let sleep: @Sendable (TimeInterval) async throws -> Void
        let journal: IrxJournal?

        init(
            connect: @escaping @Sendable (URLRequest) async throws -> any V2ControlSocket = {
                V2URLSessionSocket(session: .shared, request: $0)
            },
            http: @escaping @Sendable (URLRequest) async throws -> V2HTTPResponse = { request in
                try await V2URLSessionHTTPTransport(session: .shared).send(request)
            },
            sign: @escaping @Sendable (Data) async throws -> Data,
            signWithdrawal: (@Sendable (Data) async throws -> Data)? = nil,
            now: @escaping @Sendable () -> Date = { Date() },
            sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
                try await Task.sleep(for: .seconds(max(0, seconds)))
            },
            journal: IrxJournal? = nil
        ) {
            self.connect = connect
            self.http = http
            self.sign = sign
            self.signWithdrawal = signWithdrawal ?? sign
            self.now = now
            self.sleep = sleep
            self.journal = journal
        }
    }

    enum Phase: Equatable, Sendable {
        case idle, connecting, ready, backingOff, unsupported, stopped
        /// The service refused these credentials; team-only until new ones arrive.
        case refused
    }

    /// A Worker without the account route is retried rarely; a deploy is not urgent.
    static let unsupportedRetryDelay: TimeInterval = 6 * 60 * 60
    static let maximumRetryDelay: TimeInterval = 5 * 60
    static let pingInterval: TimeInterval = 30
    static let withdrawTimeout: TimeInterval = 5

    private let baseURL: URL
    private let dependencies: Dependencies
    private let codec = V2WireSigningCodec()
    private var credentials: Credentials?
    private var latest: AccountMacDirectorySnapshot?
    private var runID: UUID?
    private var runTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var unsupportedUntil: Date?
    private var consecutiveFailures = 0
    /// Whether a socket under the current credentials reached ready, so a
    /// publish may have committed and a withdrawal is owed.
    private var mayBePublished = false
    private(set) var phase: Phase = .idle

    init(baseURL: URL, dependencies: Dependencies) {
        self.baseURL = baseURL
        self.dependencies = dependencies
    }

    /// The latest directory fetched under the current credentials, or nil.
    /// Consumers check its lease against their own monotonic-bounded clock.
    func snapshot() -> AccountMacDirectorySnapshot? {
        guard let credentials, let latest, latest.belongs(to: credentials.device) else { return nil }
        return latest
    }

    /// Whether the deployed service lacks the account route.
    var isUnsupported: Bool { phase == .unsupported }

    /// Yields once on subscription and after every directory change, including
    /// a directory becoming unavailable.
    func changes() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard phase != .stopped else { continuation.finish(); return stream }
        observers[id] = continuation
        continuation.yield(())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    /// Installs the team control service's current credentials. A new ticket,
    /// key, team or capability set reconnects; nil disconnects without withdrawing.
    func update(_ next: Credentials?) {
        guard phase != .stopped else { return }
        let reconnect = next?.connectionKey != credentials?.connectionKey
        let identityChanged: Bool = {
            guard let next, let current = credentials else { return true }
            return current.device.identity != next.device.identity
                || current.device.endpointID != next.device.endpointID
                || current.device.identityGeneration != next.device.identityGeneration
        }()
        credentials = next
        guard reconnect else { return }
        if identityChanged {
            mayBePublished = false
            clearDirectory()
        }
        restart()
    }

    /// Removes this Mac from the account directory, then stops. Bounded so a
    /// team switch never waits on an unreachable service.
    func withdraw() async {
        let owed = mayBePublished && phase != .unsupported ? credentials : nil
        stop()
        guard let owed, owed.ticket.expiresAt > Int(dependencies.now().timeIntervalSince1970) else { return }
        let dependencies = dependencies
        guard let request = try? await makeWithdrawRequest(owed) else { return }
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                guard let response = try? await dependencies.http(request) else { return false }
                return (200..<300).contains(response.status)
            }
            group.addTask {
                try? await dependencies.sleep(Self.withdrawTimeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        dependencies.journal?.record("account-directory", "withdrawn", ["ok": String(completed)])
    }

    /// Stops without withdrawing.
    func stop() {
        guard phase != .stopped else { return }
        runTask?.cancel()
        runTask = nil
        runID = nil
        endExchange()
        phase = .stopped
        latest = nil
        for observer in observers.values {
            observer.yield(())
            observer.finish()
        }
        observers.removeAll()
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func clearDirectory() {
        guard latest != nil else { return }
        latest = nil
        notify()
    }

    private func notify() {
        for observer in observers.values { observer.yield(()) }
    }

    private func restart() {
        runTask?.cancel()
        runTask = nil
        endExchange()
        guard let credentials else {
            runID = nil
            phase = .idle
            return
        }
        let id = UUID()
        runID = id
        runTask = Task { [weak self] in await self?.run(id, credentials) }
    }

    private func isCurrent(_ id: UUID) -> Bool { runID == id && !Task.isCancelled }

    private func run(_ id: UUID, _ credentials: Credentials) async {
        while isCurrent(id) {
            if let until = unsupportedUntil {
                let remaining = until.timeIntervalSince(dependencies.now())
                if remaining > 0 {
                    phase = .unsupported
                    do { try await dependencies.sleep(remaining) } catch { return }
                    continue
                }
                unsupportedUntil = nil
            }
            do {
                phase = .connecting
                try await session(id, credentials)
                throw V2ControlFailure.unavailable
            } catch {
                guard isCurrent(id) else { return }
                endExchange()
                if Self.isUnsupported(error) {
                    unsupportedUntil = dependencies.now().addingTimeInterval(Self.unsupportedRetryDelay)
                    phase = .unsupported
                    clearDirectory()
                    dependencies.journal?.record("account-directory", "unsupported", [:])
                    continue
                }
                if Self.isRefusal(error) {
                    // The service refused this installation under these
                    // credentials (revoked, ineligible, oversized record,
                    // expired ticket). Stay team-only until the team control
                    // service hands over new credentials; never hot-loop.
                    phase = .refused
                    clearDirectory()
                    dependencies.journal?.record("account-directory", "refused", ["failure": Self.diagnostic(error)])
                    return
                }
                phase = .backingOff
                let delay = retryDelay(after: error)
                consecutiveFailures += 1
                dependencies.journal?.record("account-directory", "backing-off", [
                    "failure": Self.diagnostic(error), "delay_s": String(Int(delay)),
                ])
                do { try await dependencies.sleep(delay) } catch { return }
            }
        }
    }

    nonisolated static func isUnsupported(_ error: any Error) -> Bool {
        if case .http(let status, _)? = error as? V2ControlFailure { return status == 404 }
        if case .server(let code, _)? = error as? AccountMacDirectoryFailure { return code == "unsupported_method" }
        return false
    }

    /// Failures that a retry under the same credentials cannot fix.
    nonisolated static func isRefusal(_ error: any Error) -> Bool {
        switch error as? V2ControlFailure {
        case .http(let status, _)?: return status == 401 || status == 403
        case .socketClosed(let code, _)?: return code == 1008
        case .scopeMismatch?: return true
        default: break
        }
        if case .server(let code, _)? = error as? AccountMacDirectoryFailure {
            return AccountMacDirectoryWire.credentialFailures.contains(code) || code == "payload_too_large"
        }
        return false
    }

    private nonisolated static func diagnostic(_ error: any Error) -> String {
        if let failure = error as? V2ControlFailure { return failure.diagnosticCode }
        if case .server(let code, _)? = error as? AccountMacDirectoryFailure { return code }
        return String(describing: type(of: error))
    }

    private func retryDelay(after error: any Error) -> TimeInterval {
        let ladder = min(5 * pow(2, Double(min(consecutiveFailures, 16))), Self.maximumRetryDelay)
        var floor: TimeInterval = 0
        if case .server(_, let retryAfter)? = error as? AccountMacDirectoryFailure { floor = retryAfter ?? 0 }
        if case .http(_, let retryAfter)? = error as? V2ControlFailure { floor = retryAfter ?? 0 }
        return max(ladder, floor)
    }

    private func session(_ id: UUID, _ credentials: Credentials) async throws {
        let socket = try await dependencies.connect(try await makeSocketRequest(credentials))
        let dependencies = dependencies
        // A pending receive does not observe task cancellation, so closing the
        // socket is what releases it: on stop, and when either child ends.
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while true {
                        try await dependencies.sleep(Self.pingInterval)
                        try await socket.ping()
                    }
                }
                group.addTask { try await self.converse(id, credentials, socket) }
                defer { group.cancelAll() }
                do {
                    try await group.next()
                } catch {
                    await socket.close()
                    throw error
                }
                await socket.close()
            }
        } onCancel: {
            Task { await socket.close() }
        }
    }

    /// Request state for the one live socket. Requests are matched by ID, so
    /// a late answer to an abandoned request is ignored.
    private struct Exchange {
        var socket: (any V2ControlSocket)?
        var runID: UUID?
        var publishID: String?
        var directoryID: String?
        /// Pages of the read in progress, in cursor order.
        var pages: [AccountMacDirectory] = []
        /// A change arrived during a read; read again from the start after it.
        var rereadQueued = false
        var resyncAttempts = 0
        var refreshTask: Task<Void, Never>?
        var readTimeoutTask: Task<Void, Never>?
    }

    private var exchange = Exchange()

    private func endExchange() {
        exchange.refreshTask?.cancel()
        exchange.readTimeoutTask?.cancel()
        exchange = Exchange()
    }

    private func converse(_ id: UUID, _ credentials: Credentials, _ socket: any V2ControlSocket) async throws {
        let ready = try Self.envelope(try await socket.receive())
        guard isCurrent(id) else { throw CancellationError() }
        guard ready.schemaId == "account.ready.v1" else { throw Self.failure(ready) }
        phase = .ready
        mayBePublished = true
        endExchange()
        exchange.socket = socket
        exchange.runID = id
        try await sendPublish()
        try await beginDirectoryRead()
        while true {
            let data = try await socket.receive()
            guard isCurrent(id) else { throw CancellationError() }
            guard data.count <= 2 * 1024 * 1024 else { throw V2ControlFailure.capacityExceeded }
            let frame = try Self.envelope(data)
            switch frame.schemaId {
            case "account.directory.result.v1":
                guard let result = try? JSONDecoder().decode(AccountMacDirectoryWire.DirectoryResult.self, from: data) else {
                    throw AccountMacDirectoryFailure.invalidFrame
                }
                try await receivePage(result, credentials: credentials)
            case "account.published.v1":
                if frame.requestId == exchange.publishID { exchange.publishID = nil }
            case "account.changed.v1":
                guard frame.userId == nil || frame.userId == credentials.device.identity.userID else { continue }
                try await beginDirectoryRead()
            case "error.v1":
                try await receiveError(frame)
            default:
                // ready and withdrawn acknowledgements, and frames a newer
                // service adds, carry no directory state.
                continue
            }
        }
    }

    private func send(_ request: AccountMacDirectoryWire.Request) async throws {
        guard let socket = exchange.socket else { throw V2ControlFailure.unavailable }
        try await socket.send(try codec.encode(request))
    }

    private func sendPublish() async throws {
        let id = Self.newRequestID()
        exchange.publishID = id
        try await send(.publish(id))
    }

    /// Starts a complete read from the first page, or queues one behind the read in progress.
    private func beginDirectoryRead() async throws {
        guard exchange.directoryID == nil else {
            exchange.rereadQueued = true
            return
        }
        exchange.pages = []
        exchange.rereadQueued = false
        let id = Self.newRequestID()
        exchange.directoryID = id
        armReadTimeout(id)
        try await send(.directory(id))
    }

    private func receivePage(_ result: AccountMacDirectoryWire.DirectoryResult, credentials: Credentials) async throws {
        guard result.requestId == exchange.directoryID else { return }
        let page = result.directory
        guard page.userID == credentials.device.identity.userID else { throw V2ControlFailure.scopeMismatch }
        if let first = exchange.pages.first {
            // Pages of one read share a revision; the service refuses a stale cursor.
            guard page.revision == first.revision, page.userID == first.userID else {
                throw AccountMacDirectoryFailure.invalidFrame
            }
        }
        exchange.pages.append(page)
        if let cursor = page.nextCursor {
            let previous = exchange.pages.dropLast().last?.nextCursor
            guard exchange.pages.count < Self.maximumPages, previous.map({ cursor > $0 }) ?? true else {
                throw AccountMacDirectoryFailure.invalidFrame
            }
            let id = Self.newRequestID()
            exchange.directoryID = id
            armReadTimeout(id)
            try await send(.directory(id, cursor: cursor, haveRevision: page.revision))
            return
        }
        let complete = AccountMacDirectory.assembled(exchange.pages)
        exchange.directoryID = nil
        exchange.readTimeoutTask?.cancel()
        exchange.pages = []
        exchange.resyncAttempts = 0
        guard let complete else { throw AccountMacDirectoryFailure.invalidFrame }
        // Only a complete read proves the session works; a socket that
        // reaches ready and then fails keeps climbing the backoff ladder.
        consecutiveFailures = 0
        accept(complete, credentials: credentials)
        scheduleRefresh(for: complete)
        if exchange.rereadQueued { try await beginDirectoryRead() }
    }

    private func receiveError(_ frame: AccountMacDirectoryWire.Envelope) async throws {
        let failure = Self.failure(frame)
        guard case .server(let code, let retryAfter) = failure, code == "resync_required" else { throw failure }
        let publish = frame.requestId != nil && frame.requestId == exchange.publishID
        let directory = frame.requestId != nil && frame.requestId == exchange.directoryID
        guard publish || directory else { throw failure }
        // The service could not read a consistent view; retry a bounded
        // number of times, then reconnect with backoff.
        exchange.resyncAttempts += 1
        guard exchange.resyncAttempts <= Self.maximumResyncAttempts else { throw failure }
        let delay = max(retryAfter ?? 0, 0.25 * pow(2, Double(exchange.resyncAttempts - 1)))
        try await dependencies.sleep(delay)
        guard exchange.socket != nil else { throw V2ControlFailure.unavailable }
        if publish {
            try await sendPublish()
        } else {
            exchange.directoryID = nil
            try await beginDirectoryRead()
        }
    }

    /// A directory request with no answer fails the socket, which reconnects
    /// with backoff, instead of blocking every later read while leases lapse.
    private func armReadTimeout(_ requestID: String) {
        exchange.readTimeoutTask?.cancel()
        guard let run = exchange.runID else { return }
        let sleep = dependencies.sleep
        exchange.readTimeoutTask = Task { [weak self] in
            do { try await sleep(Self.readTimeout) } catch { return }
            await self?.readTimedOut(run, requestID: requestID)
        }
    }

    private func readTimedOut(_ run: UUID, requestID: String) async {
        guard runID == run, exchange.runID == run, exchange.directoryID == requestID,
              let socket = exchange.socket else { return }
        dependencies.journal?.record("account-directory", "read-timed-out", [:])
        await socket.close()
    }

    static let readTimeout: TimeInterval = 15

    /// Re-reads before the earliest inbound grant or the directory lapses, so
    /// a host keeps admitting a still-authorized Mac without a gap.
    private func scheduleRefresh(for directory: AccountMacDirectory) {
        exchange.refreshTask?.cancel()
        guard let id = exchange.runID else { return }
        let delay = Self.refreshDelay(for: directory, now: dependencies.now())
        let sleep = dependencies.sleep
        exchange.refreshTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            await self?.refreshDue(id)
        }
    }

    private func refreshDue(_ id: UUID) async {
        guard runID == id, exchange.runID == id, exchange.socket != nil else { return }
        do {
            try await beginDirectoryRead()
        } catch {
            // The receive loop observes the same socket failure and reconnects.
            await exchange.socket?.close()
        }
    }

    /// Seconds until the next read: ahead of the earliest grant or directory
    /// expiry by a third of its lifetime, at most one minute, never under a second.
    nonisolated static func refreshDelay(for directory: AccountMacDirectory, now: Date) -> TimeInterval {
        let expiries = [directory.permissionExpiresAt] + directory.inboundMacs.map(\.permissionExpiresAt)
        let earliest = Double(expiries.min() ?? directory.permissionExpiresAt)
        let lifetime = max(0, earliest - Double(directory.issuedAt))
        let lead = min(60, lifetime / 3)
        return max(1, earliest - lead - now.timeIntervalSince1970)
    }

    static let maximumPages = 32
    static let maximumResyncAttempts = 3

    private func accept(_ directory: AccountMacDirectory, credentials: Credentials) {
        if let latest, latest.belongs(to: credentials.device),
           (directory.revision, directory.issuedAt) < (latest.directory.revision, latest.directory.issuedAt) {
            return
        }
        let next = AccountMacDirectorySnapshot(directory: directory, requester: credentials.device)
        guard next != latest else { return }
        latest = next
        notify()
    }

    private nonisolated static func envelope(_ data: Data) throws -> AccountMacDirectoryWire.Envelope {
        guard let frame = try? JSONDecoder().decode(AccountMacDirectoryWire.Envelope.self, from: data) else {
            throw AccountMacDirectoryFailure.invalidFrame
        }
        return frame
    }

    private nonisolated static func failure(_ frame: AccountMacDirectoryWire.Envelope) -> AccountMacDirectoryFailure {
        guard frame.schemaId == "error.v1", let code = frame.code else { return .invalidFrame }
        return .server(code: code, retryAfter: frame.retryAfterMs.map { Double($0) / 1000 })
    }

    private nonisolated static func newRequestID() -> String { UUID().uuidString.lowercased() }

    /// A 128-bit proof nonce in the 22-character base64url form the Worker requires.
    nonisolated static func newProofNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return V2WireSigningCodec().base64URL(bytes)
    }

    /// Signs `body` with the account purpose for `credentials.device`.
    private func proof<Body: Encodable>(_ credentials: Credentials, requestID: String, body: Body,
                                        sign: (@Sendable (Data) async throws -> Data)? = nil) async throws -> V2DeviceProof {
        let issuedAt = Int(dependencies.now().timeIntervalSince1970)
        let nonce = Self.newProofNonce()
        let device = credentials.device
        let bytes = try codec.encode(AccountMacDirectoryWire.ProofBody(
            identity: device.identity, endpointId: device.endpointID,
            identityGeneration: device.identityGeneration, requestId: requestID,
            issuedAt: issuedAt, nonce: nonce, body: body))
        let signature = try await (sign ?? dependencies.sign)(bytes)
        return V2DeviceProof(issuedAt: issuedAt, nonce: nonce, requestID: requestID, signature: codec.base64URL(signature))
    }

    private func signedSetup(_ credentials: Credentials, requestID: String, proof: V2DeviceProof) throws -> String {
        let setup = V2SocketSetup(device: credentials.device, haveRevision: nil, proof: proof,
            requestID: requestID, schemaID: .sessionOpenV1)
        let bytes = try codec.encode(setup)
        guard bytes.count <= 16 * 1024 else { throw V2ControlFailure.capacityExceeded }
        return codec.base64URL(bytes)
    }

    /// The socket proof covers the setup alone, exactly as `AccountBroker.authorize` verifies it.
    func makeSocketRequest(_ credentials: Credentials) async throws -> URLRequest {
        let requestID = Self.newRequestID()
        let unsigned = V2SocketSetup(device: credentials.device, haveRevision: nil, proof: nil,
            requestID: requestID, schemaID: .sessionOpenV1)
        let proof = try await proof(credentials, requestID: requestID, body: unsigned)
        var components = URLComponents(url: baseURL.appendingPathComponent("v2/account/socket"), resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        guard let url = components?.url else { throw V2ControlFailure.scopeMismatch }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("IrohTicket " + credentials.ticket.token, forHTTPHeaderField: "Authorization")
        request.setValue(try signedSetup(credentials, requestID: requestID, proof: proof),
            forHTTPHeaderField: "x-cmux-v2-setup")
        return request
    }

    /// An HTTP proof covers `{setup, request}`, so withdrawal works without a live socket.
    func makeWithdrawRequest(_ credentials: Credentials) async throws -> URLRequest {
        let requestID = Self.newRequestID()
        let unsigned = V2SocketSetup(device: credentials.device, haveRevision: nil, proof: nil,
            requestID: requestID, schemaID: .sessionOpenV1)
        let operation = AccountMacDirectoryWire.Request.withdraw(requestID)
        let proof = try await proof(credentials, requestID: requestID,
            body: AccountMacDirectoryWire.HTTPProofBody(setup: unsigned, request: operation),
            sign: dependencies.signWithdrawal)
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/account/requests"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.withdrawTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("IrohTicket " + credentials.ticket.token, forHTTPHeaderField: "Authorization")
        request.setValue(try signedSetup(credentials, requestID: requestID, proof: proof),
            forHTTPHeaderField: "x-cmux-v2-setup")
        request.httpBody = try codec.encode(operation)
        return request
    }
}
