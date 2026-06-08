import Foundation

/// Resolves the brand-logo asset to show on a terminal tab for a detected agent.
///
/// This is the single source of truth mapping cmux agent status keys (the live agent-hook
/// signal, e.g. `claude_code`, `codex`, `grok`) and process-scan kinds (e.g. `augment`) to
/// `AgentIcons/*` asset-catalog entries. It is a pure, `Sendable` value with no AppKit or
/// I/O dependency so it can be unit-tested in isolation.
struct AgentTabIconResolver: Sendable {
    /// Agent status keys mapped to their asset-catalog image name.
    ///
    /// Only agents that have a dedicated brand mark in `Assets.xcassets/AgentIcons` are listed;
    /// any other status key resolves to `nil`, leaving the default terminal icon in place.
    static let assetNameByStatusKey: [String: String] = [
        "claude_code": "AgentIcons/Claude",
        "codex": "AgentIcons/Codex",
        "grok": "AgentIcons/Grok",
        "augment": "AgentIcons/Augment",
        "cursor": "AgentIcons/Cursor",
        "antigravity": "AgentIcons/Antigravity",
        "pi": "AgentIcons/Pi",
        "opencode": "AgentIcons/OpenCode",
        "rovodev": "AgentIcons/RovoDev",
        "hermes-agent": "AgentIcons/HermesAgent",
    ]

    /// Priority order used to pick a single winner when more than one agent is attributed
    /// to the same pane. The user-requested brands come first, then remaining keyed agents.
    static let priorityOrderedStatusKeys: [String] = [
        "claude_code",
        "codex",
        "augment",
        "grok",
        "cursor",
        "antigravity",
        "pi",
        "opencode",
        "rovodev",
        "hermes-agent",
    ]

    /// Process names, executable basenames, or argv-token basenames mapped to the agent status key,
    /// for agents detected by periodic process scan rather than the `set_agent_pid` hook.
    ///
    /// Only Claude Code reports a PID through the agent hook, so every other brand (Augment, Codex,
    /// Grok, Antigravity) is identified here by matching the foreground process the same way
    /// `VaultAgentRegistry` does. Tokens are matched case-insensitively against the process `comm`
    /// name, the executable path basename, and each argv-token basename (covering `node …/auggie`
    /// style script launches).
    static let scanStatusKeyByProcessToken: [String: String] = [
        "auggie": "augment",
        "augment": "augment",
        "codex": "codex",
        "grok": "grok",
        "grok-macos-aarch64": "grok",
        "grok-macos-aarch": "grok",
        "agy": "antigravity",
        "antigravity": "antigravity",
        "cursor-agent": "cursor",
    ]

    /// Stable argv path fragments mapped to the agent status key, for agents whose wrapper execs
    /// a generic interpreter (`node`) under an alias whose argv-token basenames do not identify it.
    ///
    /// `cursor-agent` is a bash wrapper that runs `node …/cursor-agent/versions/<v>/index.js` via
    /// `exec -a "$0"`; the argv-token basenames are only `node`/`index.js`/the invocation alias
    /// (`cursor-agent` *or* the bare `agent` symlink). The exec'd script path always contains the
    /// `cursor-agent` fragment regardless of how it was launched, so matching that substring is the
    /// robust signal (and is specific enough to avoid false positives like `ssh-agent`).
    static let scanStatusKeyByArgumentSubstring: [String: String] = [
        "cursor-agent": "cursor",
    ]

    /// Returns the asset name for a single status key, or `nil` when no brand icon applies.
    func assetName(forStatusKey statusKey: String) -> String? {
        Self.assetNameByStatusKey[statusKey]
    }

    /// Resolves the winning brand asset from a set of candidate status keys.
    ///
    /// - Parameter statusKeys: Status keys attributed to one pane (hook + process-scan derived).
    /// - Returns: The highest-priority matching asset name, or `nil` for the default terminal icon.
    func assetName(forStatusKeys statusKeys: Set<String>) -> String? {
        for key in Self.priorityOrderedStatusKeys where statusKeys.contains(key) {
            if let assetName = Self.assetNameByStatusKey[key] {
                return assetName
            }
        }
        return nil
    }

    /// Returns the agent status key for a scanned process, judged by its process name, executable
    /// path basename, or any argv-token basename, or `nil` when it is not a recognized scan agent.
    ///
    /// - Parameters:
    ///   - name: The process `comm`/name.
    ///   - path: The executable path, if known.
    ///   - arguments: The process argv, if known.
    /// - Returns: The matched status key (e.g. `"codex"`, `"grok"`, `"augment"`), or `nil`.
    func scanStatusKey(name: String, path: String?, arguments: [String]) -> String? {
        if let key = Self.scanStatusKeyByProcessToken[name.lowercased()] {
            return key
        }
        if let path,
           let key = Self.scanStatusKeyByProcessToken[(path as NSString).lastPathComponent.lowercased()] {
            return key
        }
        for argument in arguments {
            let basename = (argument as NSString).lastPathComponent.lowercased()
            if let key = Self.scanStatusKeyByProcessToken[basename] {
                return key
            }
        }
        for argument in arguments {
            let lowered = argument.lowercased()
            for (fragment, key) in Self.scanStatusKeyByArgumentSubstring where lowered.contains(fragment) {
                return key
            }
        }
        return nil
    }
}
