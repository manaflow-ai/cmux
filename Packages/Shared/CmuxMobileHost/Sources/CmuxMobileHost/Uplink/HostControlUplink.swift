import CmuxMobileWire
import Foundation

/// Registers this Mac with `HostDO` and serves its host role (b1-control-do.md
/// sections 2 and 3, b5-mac-host.md section 5): hello, caps and presence,
/// `workspace:<host>` snapshots and events, and ops `HostDO` forwards from
/// devices through the same policy and ledger as the link `rpc` channel.
public actor HostControlUplink {
    public static let caps = ["read", "signal", "presence", "resume"]

    private let socket: any HostControlSocket
    private let host: MobileHost
    private let signaling: (any SignalingSink)?
    private let appVersion: String
    private let install: String
    private var forwarders: [String: Task<Void, Never>] = [:]
    /// The last forwarded op per device: ops of one device run in order,
    /// different devices concurrently, and none blocks this frame loop.
    private var opChains: [String: Task<Void, Never>] = [:]
    private var nextKey: UInt64 = 0

    public init(socket: any HostControlSocket, host: MobileHost, install: String, appVersion: String,
                signaling: (any SignalingSink)? = nil) {
        self.socket = socket
        self.host = host
        self.install = install
        self.appVersion = appVersion
        self.signaling = signaling
    }

    /// Runs until the socket closes. Throws when `HostDO` refuses the hello.
    public func run() async throws {
        let frames = socket.frames
        var iterator = frames.makeAsyncIterator()
        let hello = HelloFrame(caps: Self.caps, client: HelloClient(install: install, platform: "macos", appVersion: appVersion))
        try await socket.send(MobileFrame.hello(hello).jsonValue)
        guard let first = await iterator.next() else {
            throw HostControlUplinkError(code: "owner.unreachable", message: "HostDO closed before hello.ok")
        }
        guard case .helloOK? = try? MobileFrame(value: first) else {
            await socket.close()
            throw HostControlUplinkError(code: first["code"]?.stringValue ?? "proto.hello_required",
                                         message: first["message"]?.stringValue ?? "HostDO refused the hello")
        }
        let hostID = host.configuration.hostID
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await sendOp("host.caps.set", params: .object([
            "host": .string(hostID), "proto": .object(["min": .int(1), "max": .int(1)]),
            "caps": .array(host.configuration.caps.map { .string($0) }),
        ]))
        try await sendOp("host.presence.set", params: .object([
            "host": .string(hostID), "presence": .string("online"), "at": .int(now),
        ]))
        while let frame = await iterator.next() {
            await handle(frame)
        }
        for forwarder in forwarders.values { forwarder.cancel() }
        forwarders.removeAll()
        for chain in opChains.values { chain.cancel() }
        opChains.removeAll()
    }

    private func sendOp(_ op: String, params: JSONValue) async throws {
        nextKey += 1
        let key = "mac-\(host.configuration.hostID)-\(UUID().uuidString.prefix(8))-\(nextKey)"
        try await socket.send(MobileFrame.op(OpFrame(op: op, params: params, idempotencyKey: key)).jsonValue)
    }

    private func handle(_ frame: JSONValue) async {
        switch frame["t"]?.stringValue {
        case "snapshot.request":
            guard let name = frame["stream"]?.stringValue, let owner = host.streams[name] else { return }
            if let device = frame["to"]?.stringValue {
                await sendScopedSnapshot(owner, to: device, pending: frame["pending"])
            } else {
                startForwarding(owner)
            }
        case "op":
            let from = frame["from"]?.stringValue ?? ""
            let previous = opChains[from]
            opChains[from] = Task { [weak self] in
                await previous?.value
                await self?.forwardedOp(frame)
            }
        case "read":
            guard case .int(let id)? = frame["id"] else { return }
            let op = frame["op"]?.stringValue ?? "read"
            if op == "task.list", let tasks = host.tasks {
                await answerTaskList(id: Int(id), params: frame["params"] ?? .object([:]), tasks: tasks)
                return
            }
            try? await socket.send(MobileFrame.error(ErrorFrame(id: Int(id), code: "proto.unsupported",
                                                                message: "\(op) is not served by this host",
                                                                retryable: false)).jsonValue)
        case "signal":
            guard let signaling, case .signal(let signal)? = try? MobileFrame(value: frame) else { return }
            await signaling.receive(signal)
        default:
            // Results of our own host ops, errors and unknown frames need no answer.
            return
        }
    }

    /// `read task.list` forwarded by `HostDO` (b1-control-do.md 3), answered from the projection.
    private func answerTaskList(id: Int, params: JSONValue, tasks: MobileTaskService) async {
        do {
            let value = try await tasks.list(params)
            let revision = String(await tasks.owner.headSeq)
            try? await socket.send(MobileFrame.readResult(ReadResultFrame(id: id, value: value, revision: revision)).jsonValue)
        } catch let error as MobileDaemonError {
            try? await socket.send(MobileFrame.error(ErrorFrame(id: id, code: error.code, message: error.message,
                                                                retryable: error.retryable)).jsonValue)
        } catch {
            try? await socket.send(MobileFrame.error(ErrorFrame(id: id, code: "owner.unreachable", message: "the read failed",
                                                                retryable: true)).jsonValue)
        }
    }

    /// Sends a fresh snapshot, then every event after it (a new request restarts).
    private func startForwarding(_ owner: any MobileStreamOwner) {
        forwarders[owner.stream]?.cancel()
        let socket = socket
        forwarders[owner.stream] = Task {
            guard let updates = try? await owner.updates(afterSeq: nil, epoch: nil) else { return }
            var last: UInt64?
            for await update in updates {
                if Task.isCancelled { return }
                switch update {
                case .snapshot(let snapshot):
                    last = snapshot.seq
                case .event(let event):
                    if let seen = last, event.seq <= seen { continue }
                    guard let seen = last, event.seq == seen + 1 else {
                        // Behind the buffer: HostDO would see a gap and ask again; send a snapshot now.
                        guard let snapshot = try? await owner.snapshotFrame(decided: []) else { return }
                        last = snapshot.seq
                        guard (try? await socket.send(owner.stamped(.snapshot(snapshot)))) != nil else { return }
                        continue
                    }
                    last = event.seq
                }
                guard (try? await socket.send(owner.stamped(update.frame))) != nil else { return }
            }
        }
    }

    /// A device's pending-key snapshot (b1-control-do.md section 3): only to
    /// that device, with its decided keys. The broadcast forwarder is untouched.
    private func sendScopedSnapshot(_ owner: any MobileStreamOwner, to device: String, pending: JSONValue?) async {
        let keys: [String]
        if case .array(let items)? = pending { keys = items.compactMap(\.stringValue) } else { keys = [] }
        let decided = await host.executor.decided(install: device, keys: keys)
        guard let snapshot = try? await owner.snapshotFrame(decided: decided),
              case .object(var object)? = try? owner.stamped(.snapshot(snapshot)) else { return }
        object["to"] = .string(device)
        try? await socket.send(.object(object))
    }

    private func forwardedOp(_ frame: JSONValue) async {
        guard let from = frame["from"]?.stringValue else { return }
        guard case .op(let op)? = try? MobileFrame(value: frame) else {
            // Still settle it, or HostDO holds the forward until its TTL.
            guard let key = frame["idempotency_key"]?.stringValue else { return }
            let reply = MobileOpReply(idempotencyKey: key, stream: host.workspaceStream.stream,
                                      outcome: .reject(tx: "tx_invalid", MobileOpRejection(code: "validation.invalid",
                                                                                           message: "bad op frame")),
                                      replayed: false)
            await send(reply, to: from)
            return
        }
        let actor = frame["actor"]?.objectValue ?? [:]
        // The ledger keys by install so a resend over the link dedupes here too.
        let install = actor["install"]?.stringValue ?? from
        let reply: MobileOpReply
        switch await host.authorizer.authorizeForwarded(install: install, userID: actor["user"]?.stringValue) {
        case .success(let principal):
            reply = await host.executor.execute(op, principal: principal)
        case .failure(let failure):
            let stream = op.op.hasPrefix("task.") ? host.taskStream?.stream ?? host.workspaceStream.stream
                : host.workspaceStream.stream
            reply = MobileOpReply(idempotencyKey: op.idempotencyKey, stream: stream,
                                  outcome: .reject(tx: "tx_denied", MobileOpRejection(code: failure.code, message: failure.message)),
                                  replayed: false)
        }
        await send(reply, to: from)
    }

    private func send(_ reply: MobileOpReply, to device: String) async {
        for out in reply.frames {
            guard case .object(var object)? = try? out.jsonValue else { continue }
            object["to"] = .string(device)
            try? await socket.send(.object(object))
        }
    }
}
