import CmuxNextControl
import Testing

@Suite("Launch stage registry")
struct LaunchStageRegistryTests {
    @Test("finishLaunching has no unallowlisted stage-0 task")
    func stageZeroAllowlistIsClosed() {
        #expect(LaunchStageRegistry.invalidStageZeroTasks.isEmpty)
        #expect(LaunchStageRegistry.finishLaunching.allSatisfy { (0...2).contains(Int($0.stage.rawValue)) })
    }
}
