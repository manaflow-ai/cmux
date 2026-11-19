import CmuxMobileAgentChat
import Foundation
import Testing
@testable import CmuxMobileLive

#if os(iOS)
/// Review F1 on cmux#43360: a kept chat tapped while the machine's channel opened pushed a spinner,
/// SwiftUI cancelled the list's `.task`, and the connect there never assigned its relay, so the
/// screen could stay a spinner after the Mac answered. The connect now belongs to
/// ``CloudMachineConnection``; these run the production relay over the Cloud service's fake wire.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CloudMachineConnectionTests {
    /// A Mac that answers the connect only when the test lets it.
    @MainActor final class DelayedConnect {
        var gate: CheckedContinuation<Void, Never>?
        var calls = 0
        let relay: CloudChatRelay
        let wire = CloudChatsLiveTests.Wire()
        init(_ machine: CloudChatMachine) { relay = CloudChatRelay(machine: machine, macID: "mac1") }
        func connect() async throws -> CloudChatRelay {
            calls += 1
            await withCheckedContinuation { gate = $0 }
            relay.bind(wire)
            return relay
        }
    }

    static let machine = CloudChatMachine(machineID: "vm", teamID: "team", name: "vm")

    func until(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        await ObservationWait(condition, budget: CloudChatsLiveTests.waitLimit).value
    }

    /// The tap is made before the delayed connect succeeds; the list's `.task` is then cancelled (as
    /// SwiftUI does when the chat is pushed over it). The connect still lands, and the tapped kept
    /// chat goes from waiting to a working chat that reaches the machine.
    @Test func aKeptChatTappedBeforeADelayedConnectOpensOnceItSucceeds() async throws {
        let mac = DelayedConnect(Self.machine)
        let connection = CloudMachineConnection()
        let kept = [try #require(AcpmuxSession(.object(["sessionId": .string("shared"), "name": .string("vm"),
                                                        "harness": .string("fake")])))]
        // The list's `.task`: it starts the connect, then is cancelled by the push.
        let listTask = Task { connection.open(attempt: 0, connect: mac.connect) }
        await listTask.value
        for _ in 0..<1000 where mac.gate == nil { await Task.yield() }
        let gate = try #require(mac.gate)
        // Tapped now: the pushed screen waits for the channel.
        guard case .waiting = connection.destination(for: "shared", kept: kept) else {
            Issue.record("a kept chat tapped while connecting waits for the channel"); return
        }
        listTask.cancel()
        // The list shown again (the chat popped) or re-evaluated: no second connect.
        connection.open(attempt: 0, connect: mac.connect)
        #expect(mac.calls == 1)

        gate.resume()
        #expect(await until { connection.relay?.hub.isReady == true })
        guard case .chat(let store) = connection.destination(for: "shared", kept: kept) else {
            Issue.record("the tapped chat opens once the channel is ready"); return
        }
        store.send(prompt: "hello after the wait")
        #expect(await until { !store.turns.isEmpty })
        #expect(mac.wire.sent.contains { $0.0 == "vm" && $0.1 == "shared" && $0.2 == "hello after the wait" })
        #expect(connection.relayGeneration == CloudChatsMemory.shared.generation)
        mac.relay.disconnect()
    }

    /// Reconnect is a new attempt: it connects again, and the earlier attempt's late answer is dropped.
    @Test func reconnectStartsANewAttemptAndDropsTheOldAnswer() async throws {
        let old = DelayedConnect(Self.machine)
        let new = DelayedConnect(Self.machine)
        let connection = CloudMachineConnection()
        connection.open(attempt: 0, connect: old.connect)
        for _ in 0..<1000 where old.gate == nil { await Task.yield() }
        connection.open(attempt: 1, connect: new.connect)
        for _ in 0..<1000 where new.gate == nil { await Task.yield() }
        try #require(new.gate).resume()
        #expect(await until { connection.relay === new.relay })
        try #require(old.gate).resume()
        for _ in 0..<100 { await Task.yield() }
        #expect(connection.relay === new.relay)
        old.relay.disconnect()
        new.relay.disconnect()
    }

    @Test func noMacToConnectThroughSaysSo() {
        let connection = CloudMachineConnection()
        connection.open(attempt: 0, connect: nil)
        #expect(connection.error == "Connect your Mac.")
        guard case .unavailable = connection.destination(for: "shared", kept: nil) else {
            Issue.record("no chat opens without a Mac"); return
        }
    }
}
#endif
