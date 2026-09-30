import Foundation
import Testing
@testable import CmuxNextTerminal

/// The debug PTY (`LocalPTYTerminalIO`) gives its shell the same terminal
/// identity as Ghostty and the daemon's terminals, not `TERM_PROGRAM=cmux`.
struct LocalPTYTerminalEnvironmentTests {
    @Test func matchesGhosttysTerminalIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-pty-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("ghostty").path
        try FileManager.default.createDirectory(at: root.appendingPathComponent("terminfo/78"), withIntermediateDirectories: true)
        try Data("entry".utf8).write(to: root.appendingPathComponent("terminfo/78/xterm-ghostty"))

        let env = LocalPTYTerminalIO.terminalEnvironment(resourcesDirectory: resources, version: "1.2.3")
        #expect(env == [
            "TERM": "xterm-ghostty",
            "TERMINFO": root.appendingPathComponent("terminfo").path,
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "ghostty",
            "TERM_PROGRAM_VERSION": "1.2.3",
            "GHOSTTY_RESOURCES_DIR": resources,
        ])
        let bare = LocalPTYTerminalIO.terminalEnvironment(resourcesDirectory: nil, version: nil)
        #expect(bare == ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "ghostty"])
    }
}
