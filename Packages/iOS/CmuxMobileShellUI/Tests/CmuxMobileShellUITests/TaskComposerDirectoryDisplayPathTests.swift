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

    @Test func preservesUsefulRootAndHomePathLabels() {
        let cases: [(path: String, name: String, parent: String?)] = [
            (path: "/", name: "/", parent: nil),
            (path: "~", name: "~", parent: nil),
            (path: "~/Dev/cmux/", name: "cmux", parent: "~/Dev"),
            (path: "/Users", name: "Users", parent: "/"),
        ]

        for testCase in cases {
            let display = TaskComposerDirectoryDisplayPath(path: testCase.path)
            #expect(display.name == testCase.name)
            #expect(display.parentPath == testCase.parent)
        }
    }
}
#endif
