import Foundation
import Testing
@testable import CmuxNextDaemon

/// Shells in cmux-next must see the terminal identity Ghostty gives its own
/// shells. Prompt themes pick colors from it: oh-my-zsh `half-life` uses the
/// ANSI palette (`%F{magenta}`) under `TERM=xterm-ghostty` but the fixed
/// 256-color cube (`%F{135}`) under `TERM=xterm-256color`, so the same
/// prompt showed a different purple than in Ghostty.
@Suite struct GhosttyTerminalEnvironmentTests {
    /// A bundle-shaped resources dir: `<Resources>/ghostty` next to
    /// `<Resources>/terminfo/78/xterm-ghostty`, as the cmux-next build phase
    /// (`scripts/cmux-next/bundle-ghostty-resources.sh`) lays them out.
    private func makeResources(withTerminfo: Bool) throws -> (resources: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-env-\(UUID().uuidString)")
        let resources = root.appendingPathComponent("ghostty")
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("themes"), withIntermediateDirectories: true)
        if withTerminfo {
            let entry = root.appendingPathComponent("terminfo/78")
            try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
            try Data("entry".utf8).write(to: entry.appendingPathComponent("xterm-ghostty"))
        }
        return (resources, root)
    }

    @Test func matchesWhatGhosttyExportsWhenTheTerminfoIsBundled() throws {
        let (resources, root) = try makeResources(withTerminfo: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = TerminalEnvironment.ghostty(resourcesDirectory: resources.path, version: "1.2.3-cmux")
        #expect(env == [
            "TERM": "xterm-ghostty",
            "TERMINFO": root.appendingPathComponent("terminfo").path,
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "ghostty",
            "TERM_PROGRAM_VERSION": "1.2.3-cmux",
            "GHOSTTY_RESOURCES_DIR": resources.path,
        ])
    }

    @Test func fallsBackToXterm256colorWithoutTheTerminfo() throws {
        let (resources, root) = try makeResources(withTerminfo: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = TerminalEnvironment.ghostty(resourcesDirectory: resources.path, version: nil)
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["TERMINFO"] == nil)
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["TERM_PROGRAM"] == "ghostty")
        #expect(env["TERM_PROGRAM_VERSION"] == nil)

        let none = TerminalEnvironment.ghostty(resourcesDirectory: nil, version: nil)
        #expect(none == ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "ghostty"])
    }

    /// The identity reaches both the daemon process (its default child TERM
    /// follows its own TERM) and every per-terminal `env`, although the
    /// login shell's own TERM/COLORTERM/TERM_PROGRAM are still dropped.
    @Test func reachesTheDaemonAndEveryTerminal() async throws {
        let (resources, root) = try makeResources(withTerminfo: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = TerminalEnvironment.ghostty(resourcesDirectory: resources.path, version: "1.2.3")
        let login = ["PATH": "/usr/bin", "TERM": "screen", "COLORTERM": "24bit", "TERM_PROGRAM": "Apple_Terminal"]
        let base = ["HOME": "/Users/u", "TERM": "dumb", "TERM_PROGRAM": "vscode"]

        let daemon = TerminalEnvironment.daemon(login: login, base: base, overrides: identity)
        let terminal = TerminalEnvironment.terminal(login: login, base: base).merging(identity) { _, new in new }
        for env in [daemon, terminal] {
            for (key, value) in identity { #expect(env[key] == value, "\(key)") }
        }
    }
}
