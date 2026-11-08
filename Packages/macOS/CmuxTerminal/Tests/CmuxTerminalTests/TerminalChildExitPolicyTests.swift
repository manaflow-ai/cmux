import Testing
@testable import CmuxTerminal

@Suite
struct TerminalChildExitPolicyTests {
    @Test
    func instantSpawnFailureKeepsSurfaceVisible() {
        let policy = TerminalChildExitPolicy(abnormalRuntimeMilliseconds: 250)

        #expect(policy.shouldKeepSurfaceVisible(runtimeMilliseconds: 3))
    }

    @Test
    func establishedShellExitContinuesThroughNormalClose() {
        let policy = TerminalChildExitPolicy(abnormalRuntimeMilliseconds: 250)

        #expect(!policy.shouldKeepSurfaceVisible(runtimeMilliseconds: 251))
    }
}
