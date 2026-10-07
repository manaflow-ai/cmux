import CmuxLink
import CmuxMobileHost
import CmuxMobileWire
import Foundation

/// The phone half of `cmux.mobile/1` over one `LinkSession`
/// (b5-mac-host.md section 2): the hello on the session channel with the
/// device proof, then channels with odd ids, and reads over one shared `rpc`
/// channel answered by id. The caller connects the link and closes it.
public actor MobileClientSession {
    public let link: LinkSession
    public let hostID: String
    private let signer: any MobileHelloSigner
    private var helloOK: HelloOKFrame?
    private var hello: Task<HelloOKFrame, any Error>?
    private var sessionChannel: MobileChannel?
    private var nextChannelID: UInt32 = 1
    private var rpc: MobileChannel?
    private var rpcReader: Task<Void, Never>?
    private var nextReadID = 1
    private var pendingReads: [Int: CheckedContinuation<JSONValue, any Error>] = [:]

    public init(link: LinkSession, hostID: String, signer: any MobileHelloSigner) {
        self.link = link
        self.hostID = hostID
        self.signer = signer
    }

    /// Sends hello once (concurrent callers share it) and returns `hello.ok`.
    @discardableResult
    public func start(caps: [String] = ["device-proof", "read", "resume"]) async throws -> HelloOKFrame {
        if let hello { return try await hello.value }
        let task = Task { try await self.sendHello(caps: caps) }
        hello = task
        do {
            let ok = try await task.value
            helloOK = ok
            return ok
        } catch {
            hello = nil
            throw error
        }
    }

    private func sendHello(caps: [String]) async throws -> HelloOKFrame {
        let proof = try await signer.proof(hostID: hostID, sessionID: link.sessionID)
        let hello = HelloFrame(caps: caps, client: signer.client)
        guard case .object(var object) = try MobileFrame.hello(hello).jsonValue else {
            throw MobileClientError(code: "validation.invalid", message: "hello did not encode")
        }
        object["auth"] = proof.jsonValue
        let channelLink = try await link.openChannel(ChannelDescriptor(stream: "cmux.mobile/session", reliability: .reliableOrdered,
                                                                       priority: .control))
        let channel = MobileChannel(id: 0, link: channelLink)
        do {
            try await channel.send(json: .object(object))
        } catch {
            await channel.abort()
            throw MobileClientError.disconnected
        }
        let reply = await withTaskCancellationHandler {
            await channel.receive()
        } onCancel: {
            Task { await channel.abort() }
        }
        guard case .json(let value) = reply, let frame = try? MobileFrame(value: value) else {
            await channel.abort()
            throw MobileClientError.disconnected
        }
        switch frame {
        case .helloOK(let ok):
            sessionChannel = channel
            return ok
        case .error(let error):
            await channel.abort()
            throw MobileClientError(code: error.code, message: error.message, retryable: error.retryable)
        default:
            await channel.abort()
            throw MobileClientError(code: "proto.hello_required", message: "unexpected answer to hello")
        }
    }

    /// `hello.ok.max_frame`, or the link default before hello.
    public var maxFrame: Int { helloOK?.maxFrame ?? 256 * 1024 }

    /// Opens a channel and waits for `channel.opened`; a refusal throws.
    public func open(_ kind: ChannelKind, channelClass: ChannelClass, params: [String: JSONValue],
                     priority: ChannelPriority, budgetBytes: Int? = nil, window: UInt32 = 4 * 1024 * 1024)
        async throws -> (MobileChannel, ChannelOpenedFrame) {
        try await start()
        let id = nextChannelID
        nextChannelID += 2
        let channelLink = try await link.openChannel(ChannelDescriptor(stream: "\(kind.rawValue)/\(id)", reliability: .reliableOrdered,
                                                                       priority: priority, budgetBytes: budgetBytes))
        let channel = MobileChannel(id: id, link: channelLink)
        let open = ChannelOpenFrame(channel: id, kind: kind, channelClass: channelClass, window: window, params: params)
        do {
            try await channel.send(frame: .channelOpen(open))
        } catch {
            await channel.abort()
            throw MobileClientError.disconnected
        }
        // Cancelling while the Mac prepares (a download hashes first) closes the channel.
        let answer = await withTaskCancellationHandler {
            await channel.receive()
        } onCancel: {
            Task { await channel.abort() }
        }
        try Task.checkCancellation()
        guard case .json(let reply) = answer, let frame = try? MobileFrame(value: reply) else {
            await channel.abort()
            throw MobileClientError.disconnected
        }
        switch frame {
        case .channelOpened(let opened):
            return (channel, opened)
        case .channelRefused(let refused):
            await channel.abort()
            throw MobileClientError(refused: refused)
        default:
            await channel.abort()
            throw MobileClientError(code: "proto.bad_record", message: "unexpected answer to channel.open")
        }
    }

    /// One read over the shared `rpc` channel.
    public func read(_ op: String, params: JSONValue) async throws -> JSONValue {
        let channel = try await rpcChannel()
        let id = nextReadID
        nextReadID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingReads[id] = continuation
                Task {
                    do {
                        try await channel.send(frame: .read(ReadFrame(id: id, op: op, params: params)))
                    } catch {
                        self.settle(id, .failure(MobileClientError.disconnected))
                    }
                }
            }
        } onCancel: {
            Task { await self.settle(id, .failure(CancellationError())) }
        }
    }

    /// Closes the channels this session opened (the link stays the caller's).
    public func close() async {
        rpcReader?.cancel()
        rpcReader = nil
        await rpc?.abort()
        await sessionChannel?.abort()
        failReads()
    }

    // MARK: Private

    private func rpcChannel() async throws -> MobileChannel {
        if let rpc { return rpc }
        let (channel, _) = try await open(.rpc, channelClass: .interactive, params: [:], priority: .control, window: 64 * 1024)
        if let rpc {
            await channel.abort()
            return rpc
        }
        rpc = channel
        rpcReader = Task { await self.readReplies(channel) }
        return channel
    }

    private func readReplies(_ channel: MobileChannel) async {
        while true {
            switch await channel.receive() {
            case .json(let value):
                guard let frame = try? MobileFrame(value: value) else { continue }
                switch frame {
                case .readResult(let result):
                    settle(result.id, .success(result.value))
                case .error(let error):
                    guard let id = error.id else { continue }
                    settle(id, .failure(MobileClientError(code: error.code, message: error.message, retryable: error.retryable)))
                default:
                    continue
                }
            case .binary, .gap:
                continue
            case .closed:
                rpc = nil
                failReads()
                return
            }
        }
    }

    private func settle(_ id: Int, _ result: Result<JSONValue, any Error>) {
        pendingReads.removeValue(forKey: id)?.resume(with: result)
    }

    private func failReads() {
        let pending = pendingReads
        pendingReads.removeAll()
        for continuation in pending.values { continuation.resume(throwing: MobileClientError.disconnected) }
    }
}
