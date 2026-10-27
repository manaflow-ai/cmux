@testable import CmuxNextAgentPane
import CmuxNextWakeupsTestSupport
import Foundation
import Network
import Testing

/// The agent pane's inbound queue registers the `acpmux-pane.inbound` lane: each daemon frame's check is one
/// 1 s scope and the daemon's close another, the page's wake after a pass is in none, and the lane is freed
/// with the socket. Each acpmux status connection is its own `acpmux.status` lane, held by its state handler
/// until Network drops it with the connection (plans/cmux-next/chrome-parity/p09-observability.md, section E,
/// task 119).
@Suite(.timeLimit(.minutes(1)))
struct AcpmuxPaneSocketHangScopeTests {
    nonisolated static let inbound = "acpmux-pane.inbound"

    /// A wire the test drives: it hands the socket's callbacks to the test when the socket opens it.
    nonisolated final class DrivenWire: AcpmuxPaneWire {
        struct Callbacks: Sendable {
            let frame: @Sendable (String) -> Void
            let close: @Sendable (_ code: Int, _ reason: String) -> Void
        }

        let opened: AsyncStream<Callbacks>
        private let opening: AsyncStream<Callbacks>.Continuation

        init() {
            (opened, opening) = AsyncStream.makeStream(of: Callbacks.self)
        }

        func open(onFrame: @escaping @Sendable (String) -> Void,
                  onClose: @escaping @Sendable (_ code: Int, _ reason: String) -> Void) async throws {
            opening.yield(Callbacks(frame: onFrame, close: onClose))
        }

        func send(_ text: String, completion: @escaping @Sendable (Bool) -> Void) { completion(true) }
        func cancel(code: Int, reason: String) {}
    }

    private static func socket(wire: DrivenWire?, hangs: RecordingLaneHangWatch,
                               signal: @escaping @Sendable () -> Void = {}) -> AcpmuxPaneSocket {
        let transport = AgentPaneTransport()
        let request = URLRequest(url: URL(fileURLWithPath: "/"))
        return AcpmuxPaneSocket(request: request, wire: wire, limits: transport.limits, options: transport.permissionOptions,
                                sessions: transport.sessions, ids: AcpmuxRequestIds(), hangs: hangs, signal: signal)
    }

    @Test func eachFrameAndTheCloseAreOneScopeAndThePagesWakeIsNone() async throws {
        let hangs = RecordingLaneHangWatch()
        let wire = DrivenWire()
        let (wakes, wake) = AsyncStream.makeStream(of: Int.self)
        let socket = Self.socket(wire: wire, hangs: hangs) { wake.yield(hangs.open(Self.inbound).count) }
        #expect(hangs.lanes == [Self.inbound])
        #expect(AcpmuxPaneSocket.hangDeadline == .seconds(1))

        try await socket.start(timeout: 1)
        var opened = wire.opened.makeAsyncIterator()
        let callbacks = try #require(await opened.next())
        callbacks.frame(#"{"jsonrpc":"2.0","method":"session/update","params":{"n":1}}"#)
        callbacks.frame(#"{"jsonrpc":"2.0","method":"session/update","params":{"n":2}}"#)
        callbacks.close(1000, "")

        // The pass's wake comes after both frames' scopes closed; the close's wake comes from inside its scope.
        var woken = wakes.makeAsyncIterator()
        #expect(await woken.next() == 0)
        #expect(await woken.next() == 1)
        #expect(hangs.entered(Self.inbound) == 3, "two frames and the close are not three scopes")
        #expect(hangs.entered.allSatisfy { $0.deadline == .seconds(1) })
    }

    @Test func theInboundLaneIsFreedWithTheSocket() {
        let hangs = RecordingLaneHangWatch()
        var socket: AcpmuxPaneSocket? = Self.socket(wire: nil, hangs: hangs)
        #expect(socket != nil)
        socket = nil
        #expect(hangs.unregistered == [Self.inbound])
    }

    @Test func aStatusConnectionIsOneLaneUntilItIsCancelled() async throws {
        let listener = try UnixTestListener()
        defer { listener.close() }
        let hangs = RecordingLaneHangWatch()
        var connection: NWConnection? = NWConnection(to: .unix(path: listener.path), using: .tcp)
        try await AcpmuxStatusClient.start(try #require(connection), hangs: hangs)
        #expect(hangs.lanes == ["acpmux.status"])
        #expect(hangs.entered("acpmux.status") >= 1, "the ready state was handled outside a scope")
        #expect(hangs.entered.allSatisfy { $0.deadline == .seconds(1) })
        #expect(hangs.unregistered.isEmpty, "the lane was freed while the connection is open")

        // A cancelled connection drops its handlers, and with it the lane.
        connection?.cancel()
        connection = nil
        var freed = hangs.unregistrations.makeAsyncIterator()
        #expect(await freed.next() == "acpmux.status")
    }
}
