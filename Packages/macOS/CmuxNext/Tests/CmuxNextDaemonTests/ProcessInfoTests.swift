@testable import CmuxNextDaemon
import Foundation
import Testing

/// `process-info` decoding and the "is something running" rule used to ask
/// before closing a workspace.
@Suite struct ProcessInfoTests {
    typealias Info = TerminalProcessInfoRequest.Response

    @Test func idleShellIsNotRunning() {
        #expect(Info(pid: 1, command: nil, foregroundExecutable: "/bin/zsh").runningProgram == nil)
        #expect(Info(pid: 1, command: nil, foregroundExecutable: "-zsh").runningProgram == nil)
        #expect(Info(pid: 1, command: nil, foregroundExecutable: nil).runningProgram == nil)
    }

    @Test func foregroundProgramIsRunning() {
        #expect(Info(pid: 1, command: nil, foregroundExecutable: "/usr/bin/vim").runningProgram == "vim")
        #expect(Info(pid: 1, command: "/opt/homebrew/bin/claude", foregroundExecutable: "node").runningProgram == "node")
    }

    @Test func decodesTheDaemonReply() throws {
        let line = Data(#"{"ok":true,"data":{"pid":42,"command":null,"cwd":"/tmp","foreground_cwd":"/tmp","foreground_executable":"htop"}}"#.utf8)
        let info = try WireCoding.decodeResponse(Info.self, from: line)
        #expect(info.pid == 42)
        #expect(info.runningProgram == "htop")
    }
}
