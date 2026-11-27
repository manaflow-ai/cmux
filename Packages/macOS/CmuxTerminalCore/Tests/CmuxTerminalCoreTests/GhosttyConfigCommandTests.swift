import Foundation
import Testing
@testable import CmuxTerminalCore

@Suite
struct GhosttyConfigCommandTests {
    @Test
    func parsesExplicitCommandDirective() {
        var config = GhosttyConfig()

        config.parse("command = direct:/usr/local/bin/custom-shell --login")

        #expect(config.command == "direct:/usr/local/bin/custom-shell --login")
    }

    @Test
    func emptyCommandDoesNotReplaceLastValidDirective() {
        var config = GhosttyConfig()

        config.parse(
            """
            command = /usr/local/bin/custom-shell
            command =
            """
        )

        #expect(config.command == "/usr/local/bin/custom-shell")
    }

    @Test
    func includedConfigCommandUsesResolvedFilePrecedence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shell-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let included = directory.appendingPathComponent("shell.conf")
        try "command = direct:/opt/custom/bin/fish\n".write(to: included, atomically: true, encoding: .utf8)
        let main = directory.appendingPathComponent("config")
        try "command = /bin/zsh\nconfig-file = shell.conf\n".write(to: main, atomically: true, encoding: .utf8)

        var config = GhosttyConfig()
        config.loadResolvedUserConfig(configPaths: [main.path], preferredColorScheme: .dark)

        #expect(config.command == "direct:/opt/custom/bin/fish")
    }
}
