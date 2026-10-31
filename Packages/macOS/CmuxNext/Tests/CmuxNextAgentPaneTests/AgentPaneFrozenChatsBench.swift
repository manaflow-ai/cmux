import Foundation
import Testing
@testable import CmuxNextAgentPane

/// p13-webui-080's measurement, not a CI gate: N hidden idle chats, each with its own transport, frame
/// pacer and acpmux connection, on one stand-in acpmux that sends every open connection an idle watch
/// frame ``framesPerChatPerSecond`` times a second (10 chats: 25 frames/s, the rate the plan names for
/// today's hidden chats). It counts the frames the host receives, the open connections and the page calls
/// while the chats are hidden, then frozen (``AgentPaneFramePacer/pageDidFreeze()`` and
/// ``AgentPaneTransport/closeWhileFrozen()``, what AgentPageHibernation does at the freeze), and the
/// reconnects per thaw. Fails when frozen chats keep a connection or receive 1 frame/s or more, or a thaw
/// takes other than one reconnect. Run: `scripts/measure/acpmux-overhead.sh bench=hidden [n=10]`
/// (CMUX_ACPMUX_HIDDEN_BENCH=1, CMUX_ACPMUX_HIDDEN_CHATS=N). Output: ACPMUX-HIDDEN lines.
/// skip-owner: PL-webui; expiry: 2026-11-06; tracking: handoff/followups.md "skips audit 2026-10-30"
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_ACPMUX_HIDDEN_BENCH"] == "1"))
@MainActor
struct AgentPaneFrozenChatsBench {
    static let framesPerChatPerSecond = 2.5
    static let window: Duration = .seconds(4)
    static var chats: Int { Int(ProcessInfo.processInfo.environment["CMUX_ACPMUX_HIDDEN_CHATS"] ?? "") ?? 10 }

    struct Chat {
        let transport: AgentPaneTransport
        let pacer: AgentPaneFramePacer
        let pushes: AgentPaneTransportFreezeTests.Pushes
    }

    @Test func frozenIdleChatsHoldNoConnectionAndReceiveNoFrames() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let count = Self.chats
        let connection = AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil)
        var opened: [Chat] = []
        for _ in 0..<count {
            let pushes = AgentPaneTransportFreezeTests.Pushes()
            let (transport, pacer) = AgentPaneTransportFreezeTests.rig(pushes)
            _ = try await transport.open(connection)
            opened.append(Chat(transport: transport, pacer: pacer, pushes: pushes))
        }
        let chats = opened
        await AgentPaneTransportFreezeTests.settle { server.peers.count == count }
        let interval = Duration.seconds(1 / Self.framesPerChatPerSecond)
        // task-owner: the stand-in acpmux's idle watch; cancelled when the bench ends
        let watch = Task { @MainActor in
            for seq in 0... {
                try await Task.sleep(for: interval)
                for (index, peer) in server.peers.enumerated() where !peer.closed {
                    server.push(AcpmuxStandInServer.benchFrame(seq), to: index)
                }
            }
        }
        defer { watch.cancel() }
        let received = { chats.reduce(0) { $0 + $1.pushes.frames.count + $1.transport.queuedFrames } }
        let calls = { chats.reduce(0) { $0 + $1.pushes.events.count } }
        let open = { server.peers.count { !$0.closed } }

        let hidden = await Self.rates(received: received, calls: calls)
        Self.report("hidden", chats: count, connections: open(), hidden)

        for chat in chats {
            chat.pacer.pageDidFreeze()
            chat.transport.closeWhileFrozen()
        }
        await AgentPaneTransportFreezeTests.settle { open() == 0 }
        let frozenConnections = open()
        let frozen = await Self.rates(received: received, calls: calls)
        Self.report("frozen", chats: count, connections: frozenConnections, frozen)

        for chat in chats {
            chat.transport.pageDidThaw()
            chat.pacer.pageDidThaw()
        }
        await AgentPaneTransportFreezeTests.settle { chats.allSatisfy { $0.pushes.closes == 1 } }
        // Each page's one reconnect, as its client opens again on the freeze's close.
        for chat in chats { _ = try await chat.transport.open(connection) }
        let reconnects = chats.reduce(0) { $0 + $1.transport.freezeReconnects }
        await AgentPaneTransportFreezeTests.settle { open() == count }
        print("ACPMUX-HIDDEN state=thawed chats=\(count) connections=\(open()) reconnects_per_thaw=\(Double(reconnects) / Double(count))")

        #expect(frozenConnections == 0, "frozen chats kept \(frozenConnections) acpmux connections")
        #expect(frozen.frames < 1, "frozen chats received \(frozen.frames) frames/s")
        #expect(reconnects == count, "\(count) thaws took \(reconnects) reconnects")
    }

    /// Frames the host received and page calls, each per second, over one ``window``.
    static func rates(received: () -> Int, calls: () -> Int) async -> (frames: Double, calls: Double) {
        let (frames, made, began) = (received(), calls(), ContinuousClock.now)
        try? await Task.sleep(for: window)
        let elapsed = began.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return (Double(received() - frames) / seconds, Double(calls() - made) / seconds)
    }

    static func report(_ state: String, chats: Int, connections: Int, _ rates: (frames: Double, calls: Double)) {
        print("ACPMUX-HIDDEN state=\(state) chats=\(chats) connections=\(connections) "
            + "frames_per_s=\(String(format: "%.2f", rates.frames)) page_calls_per_s=\(String(format: "%.2f", rates.calls))")
    }
}
