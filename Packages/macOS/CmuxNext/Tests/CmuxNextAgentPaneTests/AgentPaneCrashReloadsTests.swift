import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite struct AgentPaneCrashReloadsTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func aPageThatKeepsCrashingStopsReloading() {
        var reloads = AgentPaneCrashReloads()
        let decisions = (0..<5).map { reloads.shouldReload(at: start.addingTimeInterval(Double($0))) }
        #expect(decisions == [true, true, true, false, false])
    }

    @Test func crashesOutsideTheWindowAreForgotten() {
        var reloads = AgentPaneCrashReloads()
        let decisions = (0..<AgentPaneCrashReloads.limit).map { reloads.shouldReload(at: start.addingTimeInterval(Double($0))) }
        #expect(decisions.allSatisfy { $0 })
        let later = reloads.shouldReload(at: start.addingTimeInterval(AgentPaneCrashReloads.window + 1))
        #expect(later)
    }
}
