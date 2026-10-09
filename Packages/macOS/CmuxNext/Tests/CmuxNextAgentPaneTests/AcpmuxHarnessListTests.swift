import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Settings > Agents > Harnesses (cx-mg91): the rows of `_acpmux/harnesses`, and the shell line
/// Settings types into a terminal tab for `acpmux harness login`.
@Suite struct AcpmuxHarnessListTests {
    @Test func rowsNameTheSourceKindAndProblemOfEachHarness() {
        let reply: [String: Any] = ["harnesses": [
            "codex": ["argv": ["/u/bin/codex-acp"], "description": "found on PATH"],
            "claude": ["kind": "claude-stdio", "argv": ["/u/bin/claude"], "description": "found on PATH"],
            "goose": ["argv": ["/u/bin/goose", "acp"], "description": "goose (ACP Registry 1.54.0): /u/bin/goose"],
            "github-copilot-cli": ["argv": ["npx"], "source": "user-file", "sourcePath": "/u/.config/cmux/harnesses/github-copilot-cli.toml",
                                   "displayName": "GitHub Copilot"],
            "aider": ["kind": "terminal", "argv": ["aider"], "source": "managed", "sourcePath": "/Library/x.toml"],
            "grok": ["argv": ["/u/bin/grok", "agent", "stdio"], "description": "found on PATH", "probeError": "not signed in"],
            "mine": ["argv": ["python3", "agent.py"]],
        ]]
        let rows = AcpmuxHarnessRow.rows(from: reply)
        #expect(rows.map(\.id) == ["aider", "claude", "codex", "github-copilot-cli", "goose", "grok", "mine"])
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID["claude"]?.kind == "claude-stdio")
        #expect(byID["codex"]?.kind == "acp")
        #expect(byID["codex"]?.source == "path")
        #expect(byID["goose"]?.source == "registry")
        #expect(byID["github-copilot-cli"]?.source == "user-file")
        #expect(byID["github-copilot-cli"]?.name == "GitHub Copilot")
        #expect(byID["aider"]?.source == "managed")
        #expect(byID["grok"]?.problem == "not signed in")
        #expect(byID["mine"]?.source == "config")
        #expect(AcpmuxHarnessRow.rows(from: [:]).isEmpty)
    }

    @Test func theShellLineRunsThisAppsAcpmuxAgainstItsHomeWithEveryWordQuoted() {
        let environment = AcpmuxEnvironment(
            executable: URL(fileURLWithPath: "/Apps/cmux DEV.app/Contents/Resources/bin/acpmux"),
            home: URL(fileURLWithPath: "/Users/me/.acpmux/tags/dev", isDirectory: true),
            socketPath: "/Users/me/.acpmux/tags/dev/acpmux.sock", daemonArguments: [],
            childEnvironment: ["ACPMUX_HOME": "/Users/me/.acpmux/tags/dev", "ACPMUX_SOCKET": "/Users/me/.acpmux/tags/dev/acpmux.sock"]
        )
        #expect(environment.shellLine(["harness", "login", "it's"])
            == "ACPMUX_HOME='/Users/me/.acpmux/tags/dev' ACPMUX_SOCKET='/Users/me/.acpmux/tags/dev/acpmux.sock' "
            + "'/Apps/cmux DEV.app/Contents/Resources/bin/acpmux' 'harness' 'login' 'it'\\''s'")
    }
}
