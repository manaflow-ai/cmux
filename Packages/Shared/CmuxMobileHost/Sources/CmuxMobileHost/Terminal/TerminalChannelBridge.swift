import CmuxLink
import CmuxMobileLink
import CmuxMobileWire
import CmuxTerminalStream
import Foundation

/// Bridges one `terminal` channel to one daemon attach (a0-rpc.md 5.3,
/// ghostty-next.md section 2).
///
/// Host to viewer: daemon frames queue in a buffer bounded by the viewer's
/// window. The link send suspends while the viewer has not consumed; when the
/// buffer would overflow, every queued frame is dropped, the daemon is asked
/// for one snapshot (`gap`), and frames are skipped until its READY, which
/// goes out with the keyframe flag. Viewer to host: `TerminalInput` records
/// and the `terminal.*` messages.
actor TerminalChannelBridge {
    static let inboundWindow: UInt32 = 64 * 1024
    static let defaultWindow = 256 * 1024
    static let windowRange = 4 * 1024...4 * 1024 * 1024

    private let channel: MobileChannel
    private let open: ChannelOpenFrame
    private let principal: MobileDevicePrincipal
    private let owner: WorkspaceStreamOwner
    private let daemon: any MobileDaemon
    private let gate: MobileSessionGate
    private var attachment: (any MobileTerminalAttachment)?
    private var window = TerminalChannelBridge.defaultWindow

    private var queue: [TerminalOutbound] = []
    private var queuedBytes = 0
    private var awaitingKeyframe = false
    private var exited = false
    private var finished = false
    private var waiter: CheckedContinuation<TerminalOutbound?, Never>?
    private var overflowCount = 0

    /// Overflow resyncs so far (diagnostics, tests).
    var overflows: Int { overflowCount }

    init(channel: MobileChannel, open: ChannelOpenFrame, principal: MobileDevicePrincipal,
         owner: WorkspaceStreamOwner, daemon: any MobileDaemon, gate: MobileSessionGate) {
        self.channel = channel
        self.open = open
        self.principal = principal
        self.owner = owner
        self.daemon = daemon
        self.gate = gate
    }

    func run() async {
        guard let attachment = await attach() else { return }
        self.attachment = attachment
        // The phone opens terminals at `input` so its keystrokes leave first;
        // this side's output must not outrank the rpc channel (c1 section 5).
        if channel.link.descriptor.priority < .render {
            // The wire descriptor's 64 KiB input budget protects keystrokes;
            // output gets the terminal render baseline and then adapts to RTT.
            await channel.link.setSendPriority(.render, budgetBytes: ChannelDescriptor.defaultBudget(for: .render))
        }
        let opened = ChannelOpenedFrame(channel: channel.id, window: Self.inboundWindow,
                                        params: (try? JSONValue(encoding: attachment.opened))?.objectValue ?? [:],
                                        resumed: false)
        guard (try? await channel.send(frame: .channelOpened(opened))) != nil else {
            await attachment.detach()
            return
        }
        let pump = Task { [weak self] in
            for await event in attachment.events {
                guard let self else { return }
                await self.enqueue(event)
            }
            await self?.enqueue(.closed)
        }
        let sender = Task { [weak self] in await self?.drain() }
        await receiveLoop(attachment)
        pump.cancel()
        let closedBySender = finished
        finishQueue()
        await attachment.detach()
        // A sender stuck on link credit must not hold the bridge: close the
        // link (which fails its send) unless the sender already closed it.
        if !closedBySender { await channel.abort() }
        sender.cancel()
        await sender.value
    }

    // MARK: Open

    private func attach() async -> (any MobileTerminalAttachment)? {
        let params: TerminalChannelParams
        do {
            params = try JSONValue.object(open.params).decode(as: TerminalChannelParams.self)
        } catch {
            await channel.refuse(code: "validation.invalid", message: "bad terminal channel params")
            return nil
        }
        guard MobileOpPolicy.matches(params.terminal, prefix: "term_"),
              (2...10_000).contains(params.viewport.cols), (1...10_000).contains(params.viewport.rows) else {
            await channel.refuse(code: "validation.invalid", message: "terminal needs a term_ id and a viewport")
            return nil
        }
        guard let state = try? await owner.currentState() else {
            await channel.refuse(code: "owner.unreachable", message: "the daemon is unreachable", retryable: true)
            return nil
        }
        guard state.tab(showingTerminal: params.terminal) != nil else {
            await channel.refuse(code: "terminal.not_found", message: "\(params.terminal) is not on this host")
            return nil
        }
        if open.window > 0 {
            window = min(max(Int(open.window), Self.windowRange.lowerBound), Self.windowRange.upperBound)
        }
        let request = MobileTerminalAttachRequest(terminal: params.terminal, viewport: params.viewport,
                                                  visible: params.visible, counts: params.counts,
                                                  snapshotVersions: params.snapshot.format == "ghostsnp" ? params.snapshot.versions : [],
                                                  viewer: principal)
        do {
            return try await daemon.attachTerminal(request)
        } catch let error as MobileDaemonError {
            await channel.refuse(code: error.code, message: error.message, retryable: error.retryable)
        } catch {
            await channel.refuse(code: "owner.unreachable", message: "the daemon did not attach", retryable: true)
        }
        return nil
    }

    // MARK: Host to viewer

    private func enqueue(_ event: MobileTerminalEvent) async {
        guard !finished else { return }
        switch event {
        case .frame(let frame):
            await enqueue(frame)
        case .size(let generation, let cols, let rows):
            push(.message(ChannelMessage(name: "terminal.size", body: [
                "generation": .int(Int64(generation)), "cols": .int(Int64(cols)), "rows": .int(Int64(rows)),
            ])))
        case .title(let title, let cwd):
            var body: [String: JSONValue] = ["title": .string(title)]
            if let cwd { body["cwd"] = .string(cwd) }
            push(.message(ChannelMessage(name: "terminal.title", body: body)))
        case .exited(let code, let signal):
            exited = true
            var body: [String: JSONValue] = ["code": code.map { .int(Int64($0)) } ?? .null]
            if let signal { body["signal"] = .string(signal) }
            push(.message(ChannelMessage(name: "terminal.exited", body: body)))
        case .kicked(let by, let byName):
            push(.message(ChannelMessage(name: "terminal.kicked", body: ["by": .string(by), "by_name": .string(byName)])))
            push(.close(code: "terminal.kicked", message: "disconnected by \(byName)"))
        case .closed:
            push(exited ? .close(code: "terminal.exited", message: "the terminal exited")
                        : .close(code: "owner.unreachable", message: "the session host ended this attach"))
        }
    }

    private func enqueue(_ frame: TerminalFrame) async {
        if frame.kind == .snapshotReady {
            // A READY restores the screen by itself: older queued frames are moot.
            awaitingKeyframe = false
            dropQueuedFrames()
            push(.frame(frame))
            return
        }
        if awaitingKeyframe { return }
        let item = TerminalOutbound.frame(frame)
        guard queuedBytes + item.cost <= window else {
            dropQueuedFrames()
            awaitingKeyframe = true
            overflowCount += 1
            await attachment?.requestSnapshot(MobileSnapshotRequest(reason: "gap", have: nil,
                                                                    requestID: "host-overflow-\(overflowCount)"))
            return
        }
        push(item)
    }

    private func push(_ item: TerminalOutbound) {
        // Grid and title updates supersede their queued predecessors, so a
        // stalled viewer holds at most one of each.
        if case .message(let message) = item, message.name == "terminal.size" || message.name == "terminal.title" {
            queue.removeAll { if case .message(let queued) = $0 { return queued.name == message.name } else { return false } }
        }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: item)
            return
        }
        queue.append(item)
        queuedBytes += item.cost
    }

    private func dropQueuedFrames() {
        queue.removeAll { $0.isFrame }
        queuedBytes = 0
    }

    private func next() async -> TerminalOutbound? {
        if !queue.isEmpty {
            let item = queue.removeFirst()
            queuedBytes -= item.cost
            return item
        }
        if finished { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }

    private func finishQueue() {
        finished = true
        queue.removeAll()
        queuedBytes = 0
        waiter?.resume(returning: nil)
        waiter = nil
    }

    private func drain() async {
        while let item = await next() {
            do {
                switch item {
                case .frame(let frame):
                    try await channel.send(binary: frame.encoded, flags: frame.kind == .snapshotReady ? .keyframe : [])
                case .message(let message):
                    try await channel.send(message: message)
                case .close(let code, let message):
                    finishQueue()
                    await channel.close(code: code, message: message)
                    return
                }
            } catch {
                finishQueue()
                return
            }
        }
    }

    // MARK: Viewer to host

    private func receiveLoop(_ attachment: any MobileTerminalAttachment) async {
        while !finished {
            switch await channel.receive() {
            case .binary(let payload, _):
                guard await gate.isOpen else { return }
                guard let input = try? TerminalInput(decoding: payload) else {
                    await channel.close(code: "proto.bad_record", message: "bad terminal input")
                    return
                }
                await attachment.write(input)
            case .json(let value):
                guard await gate.isOpen, await handle(value, attachment) else { return }
            case .gap:
                continue
            case .closed:
                return
            }
        }
    }

    private func handle(_ value: JSONValue, _ attachment: any MobileTerminalAttachment) async -> Bool {
        guard let decoded = try? MobileJSON(value: value) else {
            await sendError(code: "proto.unknown_frame", message: "unknown record on a terminal channel")
            return true
        }
        switch decoded {
        case .frame(.channelClose):
            return false
        case .frame(let frame):
            await sendError(code: "proto.unknown_frame", message: "\(frame.type.rawValue) is not served on a terminal channel")
        case .message(let message):
            await handle(message, attachment)
        }
        return true
    }

    private func handle(_ message: ChannelMessage, _ attachment: any MobileTerminalAttachment) async {
        let body = JSONValue.object(message.body)
        switch message.name {
        case "terminal.viewport":
            guard let viewport = try? body["viewport"]?.decode(as: TerminalViewport.self) else {
                await sendError(code: "validation.invalid", message: "terminal.viewport needs a viewport")
                return
            }
            await attachment.setViewport(viewport)
        case "terminal.presence":
            guard case .bool(let visible)? = body["visible"], case .bool(let counts)? = body["counts"] else {
                await sendError(code: "validation.invalid", message: "terminal.presence needs visible and counts")
                return
            }
            await attachment.setPresence(visible: visible, counts: counts)
        case "terminal.snapshot_request":
            guard let reason = body["reason"]?.stringValue, let requestID = body["request_id"]?.stringValue else {
                await sendError(code: "validation.invalid", message: "terminal.snapshot_request needs reason and request_id")
                return
            }
            let have = body["have"].flatMap { $0 == .null ? nil : $0 }
            await attachment.requestSnapshot(MobileSnapshotRequest(reason: reason, have: have, requestID: requestID))
        default:
            do {
                for reply in try await attachment.handle(message) { push(.message(reply)) }
            } catch let error as MobileDaemonError {
                await sendError(code: error.code, message: error.message, retryable: error.retryable)
            } catch {
                await sendError(code: "owner.unreachable", message: "the session host did not answer", retryable: true)
            }
        }
    }

    private func sendError(code: String, message: String, retryable: Bool = false) async {
        try? await channel.send(frame: .error(ErrorFrame(code: code, message: message, retryable: retryable)))
    }
}
