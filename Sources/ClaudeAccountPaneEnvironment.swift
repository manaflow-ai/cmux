import CMUXAgentLaunch
import Foundation

/// The Claude account keys a switch gave a terminal pane. The panel keeps it, its session
/// snapshot persists it, and a restore replays it, so the pane stays on that account after a
/// respawn and after an app relaunch (spec D9).
///
/// It has the shape the switch hands `respawnTerminalSurface`
/// (``ClaudeAccountSwitchSurfaceEnvironment``): `overrides` holds the value of each account key
/// the pane sets, where `""` masks a key the workspace or the app's own environment supplies, and
/// `removedKeys` lists the keys the switch dropped because nothing else supplied them. Older
/// snapshots have none, and their panes restore as before.
///
/// Only ``ClaudeAccountSwitchPlanner/accountEnvironmentKeys`` are ever held, however the value is
/// made or decoded: a session file names the restored shell's environment, so any other key it
/// carries is dropped rather than replayed.
struct ClaudeAccountPaneEnvironment: Codable, Equatable, Sendable {
    /// Account keys and the values the pane's shell gets; `""` masks an inherited key.
    let overrides: [String: String]
    /// Account keys the pane runs without that nothing else supplied when it switched.
    let removedKeys: [String]

    private enum CodingKeys: String, CodingKey {
        case overrides
        case removedKeys
    }

    /// Keeps only the account keys of `overrides` and `removedKeys`.
    init(overrides: [String: String], removedKeys: [String]) {
        let accountKeys = ClaudeAccountSwitchPlanner.accountEnvironmentKeys
        self.overrides = overrides.filter { accountKeys.contains($0.key) }
        self.removedKeys = Set(removedKeys).intersection(accountKeys).sorted()
    }

    /// Decodes a record, dropping any key that is not an account key; missing fields read as empty.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            overrides: try container.decodeIfPresent([String: String].self, forKey: .overrides) ?? [:],
            removedKeys: try container.decodeIfPresent([String].self, forKey: .removedKeys) ?? []
        )
    }

    /// What a switch handed `respawnTerminalSurface`.
    init(_ surfaceEnvironment: ClaudeAccountSwitchSurfaceEnvironment) {
        self.init(overrides: surfaceEnvironment.overrides, removedKeys: Array(surfaceEnvironment.removedKeys))
    }

    /// The account keys the pane runs without, removed or masked, sorted.
    var clearedKeys: [String] {
        Set(removedKeys).union(overrides.filter { $0.value.isEmpty }.keys).sorted()
    }

    /// Each account key with the value the pane runs with, `""` for a cleared one: the shape of a
    /// switch plan's surface environment, which ``ClaudeAccountSwitchSurfaceEnvironment`` turns
    /// into overrides for the environment a new surface would inherit.
    var accountEnvironment: [String: String] {
        var environment = overrides
        for key in removedKeys { environment[key] = "" }
        return environment
    }

    /// `input` with the cleared keys unset when it runs cmux's local restore verb
    /// (` cmux restore …`), so a shell rc file that exports `CLAUDE_CONFIG_DIR` again cannot move
    /// the restored Claude to another account. The command stays bare words with an absolute
    /// `env`, which POSIX shells, fish and nushell parse alike. Any other input is unchanged.
    func restoreStartupInput(_ input: String) -> String {
        let verb = " \(AgentRestoreLaunch.cliStartupExecutableToken) restore "
        let keys = clearedKeys.filter {
            $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
        }
        guard !keys.isEmpty, input.hasPrefix(verb) else { return input }
        return " /usr/bin/env " + keys.map { "-u \($0) " }.joined() + input.dropFirst()
    }
}
