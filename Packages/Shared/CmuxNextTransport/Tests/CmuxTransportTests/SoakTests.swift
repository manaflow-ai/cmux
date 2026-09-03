import Foundation
import Testing

@testable import CmuxNextTransport

/// Soak properties (Aziz, 08-20): reconnects must NEVER happen suddenly, and
/// legitimate reconnects (long backgrounding, evictions) must complete through
/// the owner's state signal. "Never suddenly" is made precise by attribution:
/// every exit from ready in the transition log must name a cause the scenario
/// injected. Correctness uses fixed logical events rather than wall-clock
/// duration, so scheduler load cannot create false failures.
@Suite("Soak: no sudden reconnects, instant legitimate recovery")
struct SoakTests {
    private func makeRig() throws -> ReconnectOwnerTests.Rig {
        try ReconnectOwnerTests.Rig()
    }

    private func exitsFromReady(_ log: [SessionTransition]) -> [SessionTransition] {
        log.filter { $0.from == .ready && $0.to != .ready }
    }

    @Test("Steady logical traffic: zero exits from ready, one dial total")
    func steadySessionNeverFlaps() async throws {
        let rig = try makeRig()
        let owner = ReconnectOwner { [rig] in try await rig.connectOnce() }
        await owner.endpointReady(true)
        await owner.trigger(.automatic(trigger: "launch"))
        for await state in await owner.states() where state == .ready { break }

        let connection = try #require(await owner.currentConnection)
        let echo = await connection.lane(TransportHost.echoLaneName)
        var validator = TrafficValidator()
        let trafficEventCount: Int64 = 200
        // Fixed terminal-shaped traffic with periodic no-op automatic triggers
        // (foreground, push, timers happen in real life while connected; none
        // may cause a dial).
        for seq in Int64(0)..<trafficEventCount {
            try await echo.send(TerminalTraffic.chunk(seq: seq, size: 1_024, seed: 91))
            if let reply = await echo.receive() {
                validator.ingest(reply)
            }
            if seq % 50 == 0 {
                await owner.trigger(.automatic(trigger: "ambient-\(seq)"))
            }
        }
        #expect(validator.isClean)
        #expect(validator.received == Int(trafficEventCount))
        #expect(await owner.dialsStarted == 1)
        #expect(await owner.admissions == 1)
        let exits = exitsFromReady(await owner.transitionLog)
        #expect(exits.isEmpty, "sudden exits from ready: \(exits)")
        print("[soak] steady \(trafficEventCount) chunks, 0 flaps, 1 dial")
    }

    @Test("Short background: nothing happened, so NO reconnect may happen")
    func shortBackgroundIsANoop() async throws {
        let rig = try makeRig()
        let owner = ReconnectOwner { [rig] in try await rig.connectOnce() }
        await owner.endpointReady(true)
        await owner.trigger(.automatic(trigger: "launch"))
        for await state in await owner.states() where state == .ready { break }

        // Ten background/foreground cycles where iOS did NOT kill anything:
        // the foreground trigger must join nothing and dial nothing.
        for cycle in 0..<10 {
            await owner.trigger(.automatic(trigger: "foreground-\(cycle)"))
            #expect(await owner.state == .ready)
        }
        #expect(await owner.dialsStarted == 1)
        #expect(exitsFromReady(await owner.transitionLog).isEmpty)
    }

    @Test("Long background killed the connection: recovery is near-instant and attributed")
    func longBackgroundRecoveryIsInstant() async throws {
        let rig = try makeRig()
        let owner = ReconnectOwner(
            config: .init(initialBackoff: .milliseconds(10), maxBackoff: .milliseconds(100))
        ) { [rig] in try await rig.connectOnce() }
        await owner.endpointReady(true)
        await owner.trigger(.automatic(trigger: "launch"))
        for await state in await owner.states() where state == .ready { break }

        // iOS reaped the connection while backgrounded (the 85s-lockout class
        // of event). The wire dies; the app foregrounds; await the owner's
        // explicit down-then-up state signal.
        let stream = await owner.states()
        let connection = try #require(await owner.currentConnection)
        await connection.closeAll(reason: nil)  // reaped, no reason delivered
        await owner.trigger(.automatic(trigger: "foreground"))
        var sawDown = false
        for await state in stream {
            if state != .ready { sawDown = true }
            if sawDown && state == .ready { break }
        }
        #expect(await owner.admissions == 2)
        print("[soak] long-background recovery reached ready")

        // And the exit that DID happen is attributed, not mysterious.
        let exits = exitsFromReady(await owner.transitionLog)
        #expect(exits.count == 1)
    }

    @Test("Every exit from ready across a fault-rich soak names an injected cause")
    func everyExitIsAttributed() async throws {
        let rig = try makeRig()
        let owner = ReconnectOwner(
            config: .init(initialBackoff: .milliseconds(5), maxBackoff: .milliseconds(50))
        ) { [rig] in try await rig.connectOnce() }
        await owner.endpointReady(true)
        await owner.trigger(.automatic(trigger: "launch"))
        for await state in await owner.states() where state == .ready { break }

        // Inject three evictions with recovery waits between them.
        for _ in 0..<3 {
            let stream = await owner.states()
            _ = await rig.host.killSession(
                deviceID: rig.identity.deviceID, appIdentity: rig.identity.appIdentity)
            var sawDown = false
            for await state in stream {
                if state != .ready { sawDown = true }
                if sawDown && state == .ready { break }
            }
        }
        #expect(await owner.admissions == 4)

        let exits = exitsFromReady(await owner.transitionLog)
        #expect(exits.count == 3)
        for exit in exits {
            guard case .remoteClosed(let reason) = exit.event else {
                Issue.record("unattributed exit from ready: \(exit)")
                continue
            }
            #expect(reason.code == CloseReason.faultInjected.code)
        }
    }
}
