public import Foundation
import Synchronization

extension RemoteRdStreamTransport {
    // MARK: Service (rd changes B3.2 and C2)

    /// The bodies of the session service's control messages (`service`
    /// messages whose service is the hello's), in order and never dropped.
    /// Subscribe before `connect()`: bodies that arrive with no subscriber
    /// are not kept. A new call finishes the previous stream.
    public func serviceMessages() -> AsyncStream<RemoteRdJSON> {
        // concurrency-allow: rb/1 control bodies (page state, menus, dialogs), not frames; the session drains them at once into its reducer, and a dropped body would desync it
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteRdJSON.self, bufferingPolicy: .unbounded)
        let previous = state.withLock { state in
            defer { state.services = continuation }
            return state.services
        }
        previous?.finish()
        return stream
    }

    /// Sends one control message of the session's service (`body` is an
    /// rb/1 message such as `rb.navigate`). Dropped after the session ended.
    public func sendService(_ body: RemoteRdJSON) {
        queue.async { [self] in
            guard !engine.handshake.isEnded else { return }
            sendControl(.service(service: hello.service, body: body))
        }
    }

    /// Queues one service input event (opaque bytes, tag 0x80) and returns
    /// its rd input sequence number, which the service's answers name (rb's
    /// `rb.key_unhandled {input_seq}`). Nil before the welcome, after the
    /// end, when the host's welcome does not list `input.service`, or for
    /// bytes the core refuses. Waits for the transport queue, so call it
    /// from outside that queue (the main actor).
    public func sendServiceInput(_ bytes: Data, mustDeliver: Bool) -> UInt32? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { [self] in
            guard !engine.handshake.isEnded,
                  engine.handshake.welcome?.caps?.contains(Self.inputServiceCap) == true,
                  let seq = try? engine.input.sendService(bytes, mustDeliver: mustDeliver) else { return nil }
            pump()
            return seq
        }
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
        let hello = RemoteRdHello(user: user, install: install, token: token, service: remoteBrowserService, caps: [inputServiceCap])
        return RemoteRdStreamTransport(endpoint: endpoint, hello: hello, startKey: "tab", control: true, nowMicros: nowMicros)
    }
}
