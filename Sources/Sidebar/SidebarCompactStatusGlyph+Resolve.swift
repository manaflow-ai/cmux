import AppKit
import CmuxSidebar
import Foundation

/// Resolving a workspace's glyph from its agent, pull request and branch
/// state. The glyph itself (SidebarCompactStatusGlyph.swift) has no app or
/// package dependencies, so `scripts/ui-lab` can render it on its own.
extension SidebarCompactStatusGlyph {
    /// The pure inputs, captured by the snapshot factory.
    struct Input: Equatable {
        struct PullRequest: Equatable {
            let label: String
            let number: Int
            let status: SidebarPullRequestStatus
            /// True when repeated refresh failures left the row unconfirmed.
            /// A stale pull request never sets the glyph; see ``resolve(_:)``.
            var isStale = false
        }

        /// Agent-owned status entries in display order.
        var agentEntries: [SidebarStatusEntry] = []
        /// Lifecycle states of the workspace's agents (manual loaders excluded).
        var lifecycleStates: [AgentHibernationLifecycleState] = []
        /// Whether a coding agent is actively working (the spinner's signal).
        var hasActiveAgent = false
        var pullRequests: [PullRequest] = []
        var branch: String?
        var directory: String?
        /// `sidebar.compactStatusIcons`, already validated.
        var iconOverrides: [String: String] = [:]
        /// Config profiles the workspace's agents launched under, e.g. "outlook".
        var profiles: [String] = []
    }

    private static let profileLabel = String(
        localized: "sidebar.compactStatus.profile",
        defaultValue: "Profile"
    )

    static func resolve(_ input: Input) -> SidebarCompactStatusGlyph {
        let kind: Kind
        let workStates = input.agentEntries.compactMap(\.workState)
        // Waiting reports a running lifecycle on purpose (a pane with live
        // background work must not look hibernatable), so it has to be read
        // off the entries before the lifecycle branch below, and only when
        // every agent in the workspace reports it: one agent still working
        // keeps the row running.
        let everyAgentIsWaiting = !workStates.isEmpty
            && workStates.count == input.agentEntries.count
            && workStates.allSatisfy { $0 == .waiting }
        if input.agentEntries.contains(where: Self.reportsError) {
            kind = .error
        } else if input.lifecycleStates.contains(.needsInput) {
            kind = .needsInput
        } else if workStates.contains(.subagents) {
            kind = .subagents
        } else if everyAgentIsWaiting {
            kind = .waiting
        } else if input.hasActiveAgent || input.lifecycleStates.contains(.running) || input.lifecycleStates.contains(.backgroundWorkPending) {
            kind = .running
        } else if input.lifecycleStates.contains(.unknown) {
            kind = .pending
        // A stale pull request is data repeated refresh failures could not
        // confirm, so it never colors the glyph; it still lists in the tooltip.
        } else if let pullRequest = input.pullRequests.first(where: { !$0.isStale }) {
            switch pullRequest.status {
            case .open: kind = .pullRequest(.open)
            case .merged: kind = .pullRequest(.merged)
            case .closed: kind = .pullRequest(.closed)
            }
        } else if input.lifecycleStates.contains(.idle) || !input.agentEntries.isEmpty {
            kind = .idle
        } else if input.branch != nil {
            kind = .branch
        } else {
            kind = .terminal
        }
        return SidebarCompactStatusGlyph(kind: kind, tooltip: tooltip(for: input), iconOverrides: input.iconOverrides)
    }

    /// Agent hooks mark failures with the warning-triangle icon.
    private static func reportsError(_ entry: SidebarStatusEntry) -> Bool {
        entry.icon?.contains("exclamationmark.triangle") == true
    }

    private static func tooltip(for input: Input) -> String {
        var lines = input.agentEntries.map {
            line(agentDisplayName(forStatusKey: $0.key), $0.value)
        }
        // A lifecycle report can arrive before (or without) a status entry;
        // name the state so the tooltip and VoiceOver label are never empty.
        if lines.isEmpty, let state = lifecycleText(input.lifecycleStates) {
            lines.append(state)
        }
        if !input.profiles.isEmpty {
            lines.append(line(profileLabel, input.profiles.joined(separator: ", ")))
        }
        lines += input.pullRequests.map {
            line("\($0.label) #\($0.number)", pullRequestStatusText($0.status))
        }
        if let branch = input.branch {
            lines.append(branch)
        }
        if let directory = input.directory {
            lines.append(directory)
        }
        return lines.joined(separator: "\n")
    }

    private static func lifecycleText(_ states: [AgentHibernationLifecycleState]) -> String? {
        if states.contains(.running) {
            return String(localized: "agent.generic.status.running", defaultValue: "Running")
        }
        if states.contains(.backgroundWorkPending) {
            return String(localized: "agent.generic.notification.subtitle.waiting", defaultValue: "Waiting")
        }
        if states.contains(.needsInput) {
            return String(localized: "feed.status.needsInput", defaultValue: "Needs input")
        }
        if states.contains(.idle) {
            return String(localized: "agentSession.web.status.idle", defaultValue: "Idle")
        }
        return nil
    }

    private static func pullRequestStatusText(_ status: SidebarPullRequestStatus) -> String {
        switch status {
        case .open: return String(localized: "sidebar.pullRequest.statusOpen", defaultValue: "open")
        case .merged: return String(localized: "sidebar.pullRequest.statusMerged", defaultValue: "merged")
        case .closed: return String(localized: "sidebar.pullRequest.statusClosed", defaultValue: "closed")
        }
    }

    /// Splits display-ordered status entries into agent-owned entries (which
    /// compact mode folds into the glyph) and the entries that keep their
    /// metadata rows. With `compacts` off every entry stays a row.
    static func partition(
        _ entries: [SidebarStatusEntry],
        compacts: Bool,
        isAgentKey: (String) -> Bool = AgentHibernationLifecycleStatusKeys.isAllowed
    ) -> (agent: [SidebarStatusEntry], rows: [SidebarStatusEntry]) {
        guard compacts else { return ([], entries) }
        var agent: [SidebarStatusEntry] = []
        var rows: [SidebarStatusEntry] = []
        for entry in entries {
            if isAgentKey(entry.key) {
                agent.append(entry)
            } else {
                rows.append(entry)
            }
        }
        return (agent, rows)
    }

    /// Human name for an agent status key (`claude_code` -> "Claude Code").
    static func agentDisplayName(forStatusKey key: String) -> String {
        if let definition = CmuxTaskManagerCodingAgentDefinition.builtIns.first(where: {
            $0.id == key || $0.directBasenames.contains(key)
        }) {
            return definition.displayName
        }
        return key
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

extension SidebarCompactStatusGlyph {
    /// Each workspace's glyph before unread, for the group headers.
    @MainActor
    static func groupMembers(_ rows: [UUID: SidebarWorkspaceRowInput]) -> [UUID: GroupMember] {
        rows.compactMapValues { row in
            row.workspace.compactStatusGlyph.map { GroupMember(title: row.workspace.title, glyph: $0) }
        }
    }
}
