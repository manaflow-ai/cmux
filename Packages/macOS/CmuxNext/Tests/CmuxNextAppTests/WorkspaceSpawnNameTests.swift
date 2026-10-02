import CmuxNextActions
import Foundation
import Testing
@testable import CmuxNextApp

/// `cmux open <dir>` (and `cmux <dir>`, `cmux new-workspace --cwd`) reach the
/// app as `newTab` with a `cwd` and no `name`. The workspace is named after
/// the folder, like Open Folder…, instead of the daemon's generic
/// `workspace-N`.
@Suite struct WorkspaceSpawnNameTests {
    private func spawn(_ arguments: [String: ActionValue]) -> WorkspaceSpawn {
        WorkspaceSpawn(ActionInvocation(arguments: arguments, origin: .cli))
    }

    /// Regression: `cmux open ~/src/cmux` named the workspace `workspace-2`.
    @Test func aDirectoryOpenIsNamedAfterTheFolder() {
        #expect(spawn(["cwd": .string("/Users/someone/src/cmux")]).name == "cmux")
        #expect(spawn(["cwd": .string("/Users/someone/src/cmux/")]).name == "cmux")
        let home = NSHomeDirectory() as NSString
        #expect(spawn(["cwd": .string("~/src/cmux")]).cwd == home.appendingPathComponent("src/cmux"))
        #expect(spawn(["cwd": .string("~/src/cmux")]).name == "cmux")
    }

    @Test func anExplicitNameWins() {
        #expect(spawn(["cwd": .string("/tmp/cmux"), "name": .string("work")]).name == "work")
    }

    /// No cwd (Cmd-N) or the filesystem root: the daemon's default name.
    @Test func withoutAFolderNameTheDaemonNamesIt() {
        #expect(spawn([:]).name == nil)
        #expect(spawn(["cwd": .string("/")]).name == nil)
    }

    /// The Open Folder… panel names its workspace by the same rule.
    @Test func openFolderUsesTheSameName() {
        #expect(WorkspaceSpawn.folderName("/Users/someone/src/cmux") == "cmux")
        #expect(WorkspaceSpawn.folderName("/") == nil)
    }
}
