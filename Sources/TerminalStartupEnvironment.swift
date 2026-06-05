import Foundation
import CMUXAgentLaunch

extension TerminalSurface {
    struct CmuxContextEnvironment: Equatable, Sendable {
        let workspaceId: UUID
        let surfaceId: UUID
        let socketPath: String
        /// Absolute path to this workspace's Notes tree root (resolved, not
        /// necessarily created), exported as `CMUX_WORKSPACE_NOTES_DIR` so the
        /// `cmux-notes` skill can target it. `nil` when unresolved (e.g. remote).
        var workspaceNotesDir: String?
    }

    /// Per-window resolvers mapping a workspace UUID to its Notes tree root,
    /// keyed by the registrant's identity. Each main window registers its own
    /// (its `TabManager` only knows that window's workspaces); a single
    /// last-writer-wins closure would drop every other window's workspaces, so
    /// ``resolveWorkspaceNotesDirectory(_:)`` searches all registered windows.
    @MainActor private static var workspaceNotesDirectoryResolvers: [ObjectIdentifier: (UUID) -> String?] = [:]

    /// Register (or replace) a window's notes-dir resolver, keyed by `owner`
    /// (typically that window's `TabManager`). App-target DI seam — set on the
    /// main actor by the composition root, read at PTY-spawn time.
    @MainActor static func registerWorkspaceNotesDirectoryResolver(
        owner: AnyObject,
        _ resolve: @escaping (UUID) -> String?
    ) {
        workspaceNotesDirectoryResolvers[ObjectIdentifier(owner)] = resolve
    }

    /// Remove a window's resolver (e.g. when its window closes).
    @MainActor static func unregisterWorkspaceNotesDirectoryResolver(owner: AnyObject) {
        workspaceNotesDirectoryResolvers.removeValue(forKey: ObjectIdentifier(owner))
    }

    /// Resolve a workspace's Notes tree root across every registered window,
    /// returning the first match (a given workspace id lives in exactly one
    /// window's `TabManager`).
    @MainActor static func resolveWorkspaceNotesDirectory(_ workspaceId: UUID) -> String? {
        for resolve in workspaceNotesDirectoryResolvers.values {
            if let dir = resolve(workspaceId) { return dir }
        }
        return nil
    }

    static let managedTerminalType = "xterm-256color"
    static let managedTerminalProgram = "ghostty"
    static let managedColorTerm = "truecolor"

    private static let inheritedClaudeAuthSelectionEnvironmentKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX"
    ]

    static func applyManagedTerminalIdentityEnvironment(
        to environment: inout [String: String],
        protectedKeys: inout Set<String>
    ) {
        environment["TERM"] = managedTerminalType
        protectedKeys.insert("TERM")
        environment["COLORTERM"] = managedColorTerm
        protectedKeys.insert("COLORTERM")
        environment["TERM_PROGRAM"] = managedTerminalProgram
        protectedKeys.insert("TERM_PROGRAM")
    }

    static func applyManagedCmuxContextEnvironment(
        _ context: CmuxContextEnvironment,
        to environment: inout [String: String],
        protectedKeys: inout Set<String>
    ) {
        var values = [
            "CMUX_SURFACE_ID": context.surfaceId.uuidString,
            "CMUX_WORKSPACE_ID": context.workspaceId.uuidString,
            "CMUX_PANEL_ID": context.surfaceId.uuidString,
            "CMUX_TAB_ID": context.workspaceId.uuidString,
            "CMUX_SOCKET_PATH": context.socketPath
        ]
        if let notesDir = context.workspaceNotesDir, !notesDir.isEmpty {
            values["CMUX_WORKSPACE_NOTES_DIR"] = notesDir
        }

        for (key, value) in values {
            environment[key] = value
            protectedKeys.insert(key)
        }
    }

    static func applyManagedGitWatchEnvironment(
        watchGitStatusEnabled: Bool,
        showPullRequestsEnabled: Bool = true,
        to environment: inout [String: String],
        protectedKeys: inout Set<String>
    ) {
        environment["CMUX_NO_GIT_WATCH"] = watchGitStatusEnabled ? "" : "1"
        protectedKeys.insert("CMUX_NO_GIT_WATCH")
        environment["CMUX_NO_PR_WATCH"] = (watchGitStatusEnabled && showPullRequestsEnabled) ? "" : "1"
        protectedKeys.insert("CMUX_NO_PR_WATCH")
    }

    static func mergedStartupEnvironment(
        base: [String: String],
        protectedKeys: Set<String>,
        additionalEnvironment: [String: String],
        initialEnvironmentOverrides: [String: String],
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        applyHermesCodexDefaults: Bool = false
    ) -> [String: String] {
        var merged = base
        for key in inheritedClaudeAuthSelectionEnvironmentKeys where merged[key] != nil || ambientEnvironment[key] != nil {
            merged[key] = ""
        }
        for (key, value) in additionalEnvironment where !key.isEmpty && !value.isEmpty && !protectedKeys.contains(key) {
            merged[key] = value
        }
        for (key, value) in initialEnvironmentOverrides where !protectedKeys.contains(key) {
            merged[key] = value
        }
        if let claudeConfigDir = merged["CLAUDE_CONFIG_DIR"], !claudeConfigDir.isEmpty {
            merged["CLAUDE_CONFIG_DIR"] = ClaudeConfigDirectoryPath.preferredPath(claudeConfigDir)
        }
        if applyHermesCodexDefaults {
            merged = HermesAgentCodexEnvironment.applyingDefaultCodexBaseURL(
                to: merged,
                ambientEnvironment: ambientEnvironment
            )
        }
        return merged
    }
}
