import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The origin lead's question on the main-actor hops: unstructured tasks have no FIFO promise and
/// their priorities differ. The page must still get every frame once and in order, because the
/// frames' order is the socket's queue, each pacer keeps one hop outstanding, and a wake only asks
/// for a flush. Stress: a stream through each pacer while tasks of every priority keep the main
/// actor busy; the page-host delivery completion also hops.
@MainActor
@Suite(.serialized) struct AgentPaneHopOrderTests {
    nonisolated static let initialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#

    /// Delivers when told how many frames to expect, resumed once.
    final class Arrivals {
        var frames: [String] = []
        var expected = 0
        var waiter: CheckedContinuation<Void, Never>?
        func add(_ new: [String]) {
            frames += new
            if frames.count >= expected, let waiter { self.waiter = nil; waiter.resume() }
        }
        func wait(for count: Int) async {
            expected = count
            if frames.count >= count { return }
            await withCheckedContinuation { waiter = $0 }
        }
    }

    func stream(pacer: any AgentPaneTransportPacer, completionHops: Bool) async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let transport = AgentPaneTransport(pacer: pacer)
        let arrivals = Arrivals()
        transport.deliver = { event, done in
            arrivals.add(event.frames)
            // The page host's delivery: the completion hops to the main actor in its own task.
            if completionHops { Task(priority: .background) { @MainActor in done() } } else { done() }
        }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        _ = await transport.send(connection: id, frames: [Self.initialize])
        await arrivals.wait(for: 1)
        // Load: main-actor tasks of every priority, each yielding many times.
        let priorities: [TaskPriority] = [.background, .low, .utility, .medium, .userInitiated, .high]
        var load: [Task<Void, Never>] = []
        for index in 0..<60 {
            load.append(Task(priority: priorities[index % priorities.count]) { @MainActor in
                for _ in 0..<200 { await Task.yield() }
            })
        }
        let count = 3000
        for seq in 0..<count { server.push(#"{"jsonrpc":"2.0","method":"session/update","params":{"s":\#(seq)}}"#, to: 0) }
        await arrivals.wait(for: count + 1)
        for task in load { await task.value }
        let seqs = arrivals.frames.dropFirst().compactMap { text -> Int? in
            guard let range = text.range(of: #""s":"#) else { return nil }
            return Int(text[range.upperBound...].prefix { $0.isNumber })
        }
        #expect(seqs == Array(0..<count), "every frame once and in order")
    }

    @Test func theNextTurnPacerKeepsTheOrderUnderMixedPriorities() async throws {
        for _ in 0..<10 { try await stream(pacer: AgentPaneNextTurnPacer(), completionHops: false) }
    }

    @Test func theFramePacerKeepsTheOrderUnderMixedPriorities() async throws {
        for _ in 0..<10 {
            // A display link that never fires: the pacer's next-turn and deadline hops carry it.
            let pacer = AgentPaneFramePacer(frames: PacerFakeFrames(), fallback: AgentPaneDemandDeadline())
            try await stream(pacer: pacer, completionHops: true)
        }
    }
}
