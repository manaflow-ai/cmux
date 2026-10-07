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
    private var forwarder: Task<Void, Never>?
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
        forwarder?.cancel()
        forwarder = nil
    }

    private func sendOp(_ op: String, params: JSONValue) async throws {
        nextKey += 1
        let key = "mac-\(host.configuration.hostID)-\(UUID().uuidString.prefix(8))-\(nextKey)"
        try await socket.send(MobileFrame.op(OpFrame(op: op, params: params, idempotencyKey: key)).jsonValue)
    }

    private func handle(_ frame: JSONValue) async {
        switch frame["t"]?.stringValue {
        case "snapshot.request":
            guard frame["stream"]?.stringValue == host.workspaceStream.stream else { return }
            startForwarding()
        case "op":
            await forwardedOp(frame)
        case "read":
            guard case .int(let id)? = frame["id"] else { return }
            let op = frame["op"]?.stringValue ?? "read"
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

    /// Sends a fresh snapshot, then every event after it (a new request restarts).
    private func startForwarding() {
        forwarder?.cancel()
        let owner = host.workspaceStream
        let socket = socket
        forwarder = Task {
            guard let updates = try? await owner.updates(afterSeq: nil) else { return }
            var last: UInt64?
            for await update in updates {
                if Task.isCancelled { return }
                switch update {
                case .snapshot(let snapshot):
                    last = snapshot.seq
                case .event(let event):
                    guard let seen = last, event.seq == seen + 1 else {
                        // Behind the buffer: HostDO would see a gap and ask again; send a snapshot now.
                        guard let snapshot = try? await owner.snapshotFrame() else { return }
                        last = snapshot.seq
                        guard (try? await socket.send(MobileFrame.snapshot(snapshot).jsonValue)) != nil else { return }
                        continue
                    }
                    last = event.seq
                }
                guard (try? await socket.send(update.frame.jsonValue)) != nil else { return }
            }
        }
    }

    private func forwardedOp(_ frame: JSONValue) async {
        guard let from = frame["from"]?.stringValue,
              case .op(let op)? = try? MobileFrame(value: frame) else { return }
        let actor = frame["actor"]?.objectValue ?? [:]
        // The ledger keys by install so a resend over the link dedupes here too.
        let install = actor["install"]?.stringValue ?? from
        let reply: MobileOpReply
        switch await host.authorizer.authorizeForwarded(install: install, userID: actor["user"]?.stringValue) {
        case .success(let principal):
            reply = await host.executor.execute(op, principal: principal)
        case .failure(let failure):
            reply = MobileOpReply(idempotencyKey: op.idempotencyKey, stream: host.workspaceStream.stream,
                                  outcome: .reject(tx: "tx_denied", MobileOpRejection(code: failure.code, message: failure.message)),
                                  replayed: false)
        }
        for out in reply.frames {
            guard case .object(var object)? = try? out.jsonValue else { continue }
            object["to"] = .string(from)
            try? await socket.send(.object(object))
        }
    }
}
