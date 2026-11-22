import CmuxNextActions
import Testing
@testable import CmuxNextApp

/// A person's new workspace opens on the New Tab page (Leo, 2026-10-05:
/// sidebar +, the New tile, Cmd-N, first launch, a new window); scripts and
/// a workspace made to run a command get a terminal they can drive.
@Suite struct WorkspaceSpawnFirstTabTests {
    private func spawn(_ arguments: [String: ActionValue] = [:], origin: ActionOrigin) -> WorkspaceSpawn {
        WorkspaceSpawn(ActionInvocation(arguments: arguments, origin: origin))
    }

    /// Regression (dogfood 80e323c): New Workspace opened a bare terminal.
    @Test func aPersonsNewWorkspaceOpensOnTheNewTabPage() {
        #expect(spawn(origin: .user).opensNewTabPage)
        #expect(spawn(["cwd": .string("/tmp/cmux")], origin: .user).opensNewTabPage)
    }

    @Test func scriptsGetATerminal() {
        for origin in [ActionOrigin.cli, .mcp, .script, .remote, .page] {
            #expect(!spawn(origin: origin).opensNewTabPage)
        }
    }

    @Test func aCommandGetsATerminal() {
        #expect(!spawn(["command": .string("htop")], origin: .user).opensNewTabPage)
    }

    @Test func otherSpawnsKeepATerminalUnlessAsked() {
        #expect(!WorkspaceSpawn().opensNewTabPage)
        #expect(!WorkspaceSpawn(opening: "/tmp/cmux").opensNewTabPage)
    }
}
