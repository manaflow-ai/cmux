public import Foundation
import CmuxNextCompat

extension RemoteRdStreamTransport {
    // MARK: Service (rd changes B3.2 and C2)

    /// The bodies of the session service's control messages (`service`
    /// messages whose service is the hello's), in order and never dropped.
    /// Subscribe before `connect()`: bodies that arrive with no subscriber
    /// are not kept. A new call finishes the previous stream. A consumer
    /// that holds ``RemoteRdServiceOutlet/byteBound`` of them untaken ends
    /// the session, as the core ends one whose messages pass the same bound.
    public func serviceMessages() -> RemoteRdServiceMessages {
        // concurrency-allow: rb/1 control bodies (page state, menus, dialogs), not frames; the session drains them at once into its reducer, and a dropped body would desync it
        // memory: bounded-by RemoteRdServiceOutlet.byteBound (4 MiB, the core's message bound): past it the session ends
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteRdServiceMessages.Item.self, bufferingPolicy: .unbounded)
        let outlet = RemoteRdServiceOutlet(continuation)
        let previous = state.withLock { state in
            defer { state.services = outlet }
            return state.services
        }
        previous?.finish()
        return RemoteRdServiceMessages(base: stream, outlet: outlet)
    }

    /// Sends one control message of the session's service (`body` is an
    /// rb/1 message such as `rb.navigate`). Dropped after the session ended.
    /// It joins the caller's outbox, so it reaches the host in call order
    /// with the input events (``send(_:)``, ``sendServiceInput(_:mustDeliver:)``):
    /// a key sent after `rb.history` applies to the page it opens.
    public func sendService(_ body: RemoteRdJSON) {
        guard let json = try? RemoteRdControl.service(service: hello.service, body: body).json(),
              let frame = try? RemoteRdCore.streamFrame(json, control: true) else { return }
        let posted = inputChannel.withLock { channel -> Bool in
            guard !channel.ended else { return false }
            channel.outbox.append(frame)
            return true
        }
        if posted { sendOutbox() }
    }

    /// Queues one service input event (opaque bytes, tag 0x80) and returns
    /// its rd input sequence number, which the service's answers name (rb's
    /// `rb.key_unhandled {input_seq}`). Nil before the welcome, after the
    /// end, when the host's welcome does not list `input.service`, or for
    /// bytes the core refuses. Never waits for the transport queue: the
    /// number comes from the input channel's lock, and the event's packets
    /// join the caller's outbox, in call order with ``sendService(_:)`` and
    /// ``send(_:)``.
    public func sendServiceInput(_ bytes: Data, mustDeliver: Bool) -> UInt32? {
        let now = nowMicros()
        let seq = inputChannel.withLock { channel -> UInt32? in
            guard channel.acceptsService,
                  let seq = try? channel.input.sendService(bytes, mustDeliver: mustDeliver) else { return nil }
            channel.outbox += (try? channel.input.packets(nowMicros: now)) ?? []
            return seq
        }
        guard let seq else { return nil }
        sendOutbox()
        return seq
    }

    /// The access units of popup surface stream `stream` (rb/1
    /// `rb.surface.show {stream}`), buffered from the show on and finished
    /// at its `rb.surface.hide` or the session's end. One caller gets them;
    /// a stream no surface shows, or a second call, gets a finished stream.
    public func surfaceAccessUnits(stream: UInt16) -> AsyncStream<RemoteAccessUnit> {
        state.withLock { $0.surfaces.take(stream: stream) } ?? AsyncStream { $0.finish() }
    }

    /// Asks the host for an IDR on display stream `stream` (a popup surface's).
    public func requestKeyframe(stream: UInt16) {
        queue.async { [self] in
            try? engine.core.requestKeyframe(stream: stream)
            pump()
        }
    }

    /// A stream source for popup surface stream `stream` (its own decoder).
    public func surfaceSource(stream: UInt16) -> any RemoteViewStreamSource {
        RemoteRdSurfaceStreamSource(transport: self, stream: stream)
    }

    /// Opens and closes popup surface streams as the host shows and hides
    /// surfaces. Queue-confined; runs before the body reaches the service
    /// stream.
    func applySurfaceStreams(_ body: RemoteRdJSON) {
        switch RemoteRdSurfaceStreamChange(body) {
        case let .show(surface, stream):
            // A resized surface comes back on a new stream; the old one ends.
            if let old = state.withLock({ $0.surfaces.stream(of: surface) }), old != stream { closeSurfaceStream(old) }
            guard (try? engine.core.openStream(stream)) != nil else { return }
            state.withLock { $0.surfaces.start(stream: stream, surface: surface) }
        case let .hide(surface):
            guard let stream = state.withLock({ $0.surfaces.stream(of: surface) }) else { return }
            closeSurfaceStream(stream)
        case nil:
            break
        }
    }

    private func closeSurfaceStream(_ stream: UInt16) {
        try? engine.core.closeStream(stream)
        state.withLock { $0.surfaces.end(stream: stream) }
    }

    /// The rd cap that allows service input events (rd change C2).
    public static let inputServiceCap = "input.service"
    /// The remote browser tab service (`cmux.rb/1`, remote-tab-protocol.md).
    public static let remoteBrowserService = "rb/1"

    /// A transport for one remote browser tab: hello for service `rb/1` with
    /// the `input.service` cap, in control mode. The rb session itself
    /// (`rb.open`, menus, pages) runs over `serviceMessages` and
    /// `sendService`; frames of the page arrive as access units.
    public static func remoteBrowser(
        endpoint: RemoteRdLoopbackEndpoint, user: String, install: String, token: String? = nil,
        nowMicros: @escaping @Sendable () -> UInt64 = RemoteRdStreamTransport.monotonicMicros
    ) -> RemoteRdStreamTransport? {
        remoteBrowser(carrier: RemoteRdLoopbackCarrier(endpoint: endpoint), user: user, install: install, token: token, nowMicros: nowMicros)
    }

    /// The same transport over any byte path (a host on another machine).
    public static func remoteBrowser(
        carrier: any RemoteRdByteCarrier, user: String, install: String, token: String? = nil,
        nowMicros: @escaping @Sendable () -> UInt64 = RemoteRdStreamTransport.monotonicMicros
    ) -> RemoteRdStreamTransport? {
        let hello = RemoteRdHello(user: user, install: install, token: token, service: remoteBrowserService, caps: [inputServiceCap])
        return RemoteRdStreamTransport(carrier: carrier, hello: hello, startKey: "tab", control: true, nowMicros: nowMicros)
    }
}
