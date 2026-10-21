import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A quit whose daemon socket is gone decides from the host locks and leaves out the Home Chief's
/// sessions it last read (`AcpmuxQuitProof.knownChief`). Those are per daemon home, and an end that
/// keeps nothing (NIGHTLY's Chief on the app's acpmux) leaves out none: a Chief subagent host
/// still holding its lock is then an agent still running, never "ended".
struct AcpmuxQuitKnownChiefTests {
    /// A home of its own per test: the remembered sessions are process-wide and tests run in parallel.
    private func home(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/known-chief-test-\(UUID().uuidString)/\(name)", isDirectory: true)
    }

    @Test func anEndThatKeepsNothingLeavesOutNoChiefHost() {
        let app = home("app-acpmux")
        AcpmuxQuitProof.remember(chief: ["chief-turn", "chief-sub"], home: app)
        #expect(AcpmuxQuitProof.keptChief(home: app, keep: .chief) == ["chief-turn", "chief-sub"])
        #expect(AcpmuxQuitProof.keptChief(home: app, keep: .nothing).isEmpty)
    }

    @Test func anotherDaemonsCensusDoesNotReplaceTheAppDaemonsChief() {
        let app = home("app-acpmux"), oldChief = home("chief-acpmux")
        AcpmuxQuitProof.remember(chief: ["chief-turn"], home: app)
        // The move's census of the Chief home's old daemon.
        AcpmuxQuitProof.remember(chief: ["old-chief-turn"], home: oldChief)
        #expect(AcpmuxQuitProof.keptChief(home: app, keep: .chief) == ["chief-turn"])
        #expect(AcpmuxQuitProof.keptChief(home: oldChief, keep: .chief) == ["old-chief-turn"])
    }

    @Test func aChiefHostStillRunningIsReportedWhenNothingIsKept() {
        let app = home("app-acpmux")
        let facts = AcpmuxQuitProof.Facts(daemon: .free, daemonPID: nil, liveHostSessions: ["chief-sub"], unknownHostSessions: [])
        AcpmuxQuitProof.remember(chief: ["chief-sub"], home: app)
        let result = AcpmuxQuitProof.decide(facts, chief: AcpmuxQuitProof.keptChief(home: app, keep: .nothing), daemonExited: true)
        #expect(result == .agentsStillRunning(["chief-sub"]))
    }
}
