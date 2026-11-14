import Foundation
import Testing
@testable import CmuxNextDaemon

/// The close question names the program a terminal runs (Aziz 2026-11-12: "Close “IOS INTERNAL CI”? Still running:
/// 2.1.323."). Claude Code runs as `~/.local/share/claude/versions/<version>`, so the executable's file name is its
/// version: the program is named by the folder that holds its versions.
struct RunningProgramNameTests {
    private func program(_ executable: String, command: String? = nil) -> String? {
        TerminalProcessInfoRequest.Response(pid: 1, command: command, foregroundExecutable: executable).runningProgram
    }

    @Test func claudeCodeIsNamedClaudeNotItsVersion() {
        #expect(program("/Users/me/.local/share/claude/versions/2.1.323") == "claude")
    }

    @Test func aVersionedToolFolderNamesTheTool() {
        #expect(program("/Users/me/.local/share/codex/versions/v0.98.0") == "codex")
        #expect(program("/opt/.cursor/1.4/2.0.1") == "cursor")
    }

    @Test func ordinaryProgramsKeepTheirFileName() {
        #expect(program("/usr/bin/vim") == "vim")
        #expect(program("/opt/homebrew/bin/node") == "node")
        #expect(program("/usr/local/bin/python3.12") == "python3.12")
        #expect(program("/bin/zsh") == nil, "the shell runs nothing")
    }

    @Test func aBareVersionWithNoFolderKeepsItsName() {
        #expect(program("2.1.323") == "2.1.323")
        #expect(program("/2.1.323") == "2.1.323")
    }
}
