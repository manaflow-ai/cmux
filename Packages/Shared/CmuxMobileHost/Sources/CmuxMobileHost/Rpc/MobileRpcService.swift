import CmuxMobileWire
import Foundation

/// Serves one `rpc` channel: `workspace:<host>` subscriptions, ops and reads
/// (a0-rpc.md section 3.4, kind `rpc`). Requests run in arrival order.
actor MobileRpcService {
    static let inboundWindow: UInt32 = 64 * 1024

    private let channel: MobileChannel
    private let principal: MobileDevicePrincipal
    private let owner: WorkspaceStreamOwner
    private let executor: MobileOpExecutor
    private let readHandlers: [String: any MobileReadHandler]
    private let gate: MobileSessionGate
    private var forwarder: Task<Void, Never>?

    init(channel: MobileChannel, principal: MobileDevicePrincipal, owner: WorkspaceStreamOwner,
         executor: MobileOpExecutor, readHandlers: [String: any MobileReadHandler], gate: MobileSessionGate) {
        self.channel = channel
        self.principal = principal
        self.owner = owner
        self.executor = executor
        self.readHandlers = readHandlers
        self.gate = gate
    }

    func run() async {
        let opened = ChannelOpenedFrame(channel: channel.id, window: Self.inboundWindow,
                                        params: ["owner": .string(owner.hostID)], resumed: false)
        guard (try? await channel.send(frame: .channelOpened(opened))) != nil else { return }
        loop: while true {
            switch await channel.receive() {
            case .json(let value):
                if await handle(value) == false { break loop }
            case .binary:
                await sendError(code: "proto.bad_record", message: "the rpc channel carries JSON records only")
            case .gap:
                continue
            case .closed:
                break loop
            }
        }
        forwarder?.cancel()
        forwarder = nil
        await channel.finish()
    }

    /// Returns false when the channel should end.
    private func handle(_ value: JSONValue) async -> Bool {
        guard await gate.isOpen else { return false }
        let frame: MobileFrame
        do {
            frame = try MobileFrame(value: value)
        } catch let error as MobileWireError {
            await sendError(code: error.code, message: error.message)
            return true
        } catch {
            await sendError(code: "validation.invalid", message: "bad frame")
            return true
        }
        switch frame {
        case .subscribe(let f):
            guard await checkStream(f.stream) else { return true }
            await subscribe(afterSeq: f.afterSeq, epoch: value["epoch"]?.stringValue, pending: f.pending ?? [])
        case .unsubscribe(let f):
            guard await checkStream(f.stream) else { return true }
            forwarder?.cancel()
            forwarder = nil
        case .snapshotRequest(let f):
            guard await checkStream(f.stream) else { return true }
            let decided = await executor.decided(install: principal.install, keys: f.pending ?? [])
            if let snapshot = try? await owner.snapshotFrame(decided: decided) {
                try? await channel.send(json: owner.stamped(.snapshot(snapshot)))
            } else {
                await sendError(code: "owner.unreachable", message: "the daemon is unreachable", retryable: true)
            }
        case .op(let f):
            let reply = await executor.execute(f, principal: principal)
            for out in reply.frames { try? await channel.send(frame: out) }
        case .read(let f):
            await read(f)
        case .presenceSet:
            // Host presence is HostDO's; terminal presence rides terminal channels.
            break
        case .channelClose:
            return false
        default:
            await sendError(code: "proto.unknown_frame", message: "\(frame.type.rawValue) is not served on the rpc channel")
        }
        return true
    }

    private func checkStream(_ stream: String?) async -> Bool {
        guard let stream, stream != owner.stream else { return true }
        await sendError(code: "validation.invalid", message: "unknown stream \(stream)")
        return false
    }

    private func subscribe(afterSeq: UInt64?, epoch: String?, pending: [String]) async {
        forwarder?.cancel()
        let updates: AsyncStream<WorkspaceStreamUpdate>
        do {
            updates = try await owner.updates(afterSeq: pending.isEmpty ? afterSeq : nil, epoch: epoch)
        } catch {
            await sendError(code: "owner.unreachable", message: "the daemon is unreachable", retryable: true)
            return
        }
        let decided = await executor.decided(install: principal.install, keys: pending)
        let channel = channel
        let owner = owner
        let resume = pending.isEmpty ? afterSeq : nil
        forwarder = Task {
            var last: UInt64? = resume
            var first = true
            for await update in updates {
                if Task.isCancelled { return }
                switch update {
                case .snapshot(var snapshot):
                    if first { snapshot.decided = decided }
                    last = snapshot.seq
                    guard (try? await channel.send(json: owner.stamped(.snapshot(snapshot)))) != nil else { return }
                case .event(let event):
                    if let seen = last, event.seq <= seen { continue }
                    if last.map({ event.seq != $0 + 1 }) ?? true {
                        // Behind its buffer (or the opening snapshot was dropped): resync, never a gap.
                        guard let snapshot = try? await owner.snapshotFrame() else { return }
                        last = snapshot.seq
                        guard (try? await channel.send(json: owner.stamped(.snapshot(snapshot)))) != nil else { return }
                        // The snapshot was read after this event committed, so it covers it.
                        first = false
                        continue
                    }
                    last = event.seq
                    guard (try? await channel.send(json: owner.stamped(.event(event)))) != nil else { return }
                }
                first = false
            }
        }
    }

    private func read(_ frame: ReadFrame) async {
        guard let handler = readHandlers[frame.op] else {
            await sendError(id: frame.id, code: "proto.unsupported", message: "\(frame.op) is not served by this host")
            return
        }
        do {
            let value = try await handler.read(frame, principal: principal)
            let revision = String(await owner.headSeq)
            try? await channel.send(frame: .readResult(ReadResultFrame(id: frame.id, value: value, revision: revision)))
        } catch let error as MobileDaemonError {
            await sendError(id: frame.id, code: error.code, message: error.message, retryable: error.retryable)
        } catch {
            await sendError(id: frame.id, code: "owner.unreachable", message: "the read failed", retryable: true)
        }
    }

    private func sendError(id: Int? = nil, code: String, message: String, retryable: Bool = false) async {
        try? await channel.send(frame: .error(ErrorFrame(id: id, code: code, message: message, retryable: retryable)))
    }
}
