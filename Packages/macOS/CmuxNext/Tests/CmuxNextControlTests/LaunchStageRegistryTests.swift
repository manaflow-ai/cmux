import CmuxNextControl
import Testing

@Suite("Launch stage registry")
struct LaunchStageRegistryTests {
    @Test("declared stage-0 tasks stay on the shell allowlist")
    func stageZeroAllowlistIsClosed() {
        #expect(LaunchStageRegistry.invalidStageZeroTasks.isEmpty)
        #expect(LaunchStageRegistry.finishLaunching.allSatisfy { (0...2).contains(Int($0.stage.rawValue)) })
    }
}
