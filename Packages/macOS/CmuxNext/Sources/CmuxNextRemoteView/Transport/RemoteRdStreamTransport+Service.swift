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

    /// The access units of popup stream `stream` (rb/1 `rb.surface.show`).
    public func surfaceAccessUnits(stream: UInt16) -> AsyncStream<RemoteAccessUnit> {
        AsyncStream { $0.finish() }
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
