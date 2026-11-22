import Foundation
import Testing
@testable import CmuxNextAgentPane

/// UP (plans/cmux-next/durable-sessions.md section 3): after an update the
/// app hands an acpmux daemon of another build off to the bundled build, but
/// only when that daemon runs its agents under agent hosts, so the restart
/// keeps every agent running.
@Suite struct AcpmuxVersionHandoffTests {
    @Test func versionOutputCarriesTheBuild() {
        #expect(AcpmuxVersionHandoff.build(fromVersion: "acpmux 0.1.0 (227bbd155+dirty.a3fe8ee0 2026-10-03)\n")
            == "227bbd155+dirty.a3fe8ee0 2026-10-03")
        #expect(AcpmuxVersionHandoff.build(fromVersion: "acpmux 0.1.0") == nil)
    }

    @Test func handsOffOnlyADaemonWhoseAgentsSurvive() {
        let decide = AcpmuxVersionHandoff.decide
        #expect(decide("a 2026", "b 2026", true) == .restart)
        #expect(decide("a 2026", "a 2026", true) == .keep("same build"))
        #expect(decide("a 2026", "b 2026", false) == .keep("its agents would end: no agent hosts"))
        #expect(decide(nil, "b 2026", true) == .keep("running build unknown"))
        #expect(decide("a 2026", nil, true) == .keep("bundled build unknown"))
    }
}
