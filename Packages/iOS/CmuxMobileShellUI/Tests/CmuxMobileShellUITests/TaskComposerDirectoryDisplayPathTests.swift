#if os(iOS)
import Testing
@testable import CmuxMobileShellUI

@Suite struct TaskComposerDirectoryDisplayPathTests {
    @Test func separatesNearbyFolderNamesFromTheirParentPaths() {
        let projectPath = "/Users/me/Dev/Manaflow/cmuxterm-hq/worktrees/feat-ios-task-composer"

        let project = TaskComposerDirectoryDisplayPath(path: projectPath)
        let web = TaskComposerDirectoryDisplayPath(path: "\(projectPath)/web")

        #expect(project.name == "feat-ios-task-composer")
        #expect(project.parentPath == "/Users/me/Dev/Manaflow/cmuxterm-hq/worktrees")
        #expect(web.name == "web")
        #expect(web.parentPath == projectPath)
    }
}
#endif
