import Foundation
import Testing
@testable import CmuxComputerUse

struct ComputerUseSessionScopeTests {
    @Test func matchesOnlyItsStableSessionAndChildGenerations() {
        let identifier = ComputerUseSessionScope.driverSessionID(surfaceID: UUID())
        let scope = ComputerUseSessionScope(id: "row", driverSessionID: identifier)
        #expect(scope.id == "row")
        #expect(scope.matches(driverSessionID: identifier))
        #expect(scope.matches(driverSessionID: identifier + "-mcp-child"))
        #expect(!scope.matches(driverSessionID: "unrelated"))
        #expect(!scope.matches(driverSessionID: nil))
    }

    @Test func helperReplacementRequiresOnboardingAgain() {
        let phase = ComputerUseRuntimePermissionPhase.ready.applying(.helperReplaced)
        #expect(phase == .onboardingRequired)
        #expect(!phase.isReady)
        #expect(phase.applying(.onboardingCompleted).isReady)
    }
}
