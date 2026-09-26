import AppKit
import CmuxSidebar
import Foundation
import SwiftUI

/// The single leading glyph a workspace row shows when
/// `sidebar.compactAgentStatus` is on. Agent hooks report their lifecycle as
/// keyed status entries (`set_status claude_code Running --icon=bolt.fill`);
/// by default each one takes a full metadata row under the title. Compact
/// mode drops those agent-owned rows and folds agent state together with the
/// workspace's pull request and branch into one glyph, with the details in
/// its tooltip. Other status entries stay as metadata rows.
///
/// Precedence, loudest first:
/// 1. Needs attention (an agent needs input or reported an error): red
///    warning triangle.
/// 2. Running: no glyph; the row's existing loading spinner is the animated
///    running indicator. With the spinner turned off, resolution falls
///    through to the cases below.
/// 3. Pull request: green when open, purple when merged, gray when closed.
/// 4. Branch without a pull request: purple branch glyph.
/// 5. Agent idle: filled gray dot.
/// 6. Any other agent presence (starting, state unknown, or running with the
///    spinner turned off): hollow ring.
struct SidebarCompactStatusGlyph: Equatable {
    enum Kind: Equatable {
        case attention
        case pullRequestOpen
        case pullRequestMerged
        case pullRequestClosed
        case branch
        case idle
        case pending
    }

    let kind: Kind
    /// One line per fact: agent statuses, pull requests, branch.
    let tooltip: String

    var symbolName: String {
        switch kind {
        case .attention: return "exclamationmark.triangle.fill"
        case .pullRequestOpen, .pullRequestClosed: return "arrow.triangle.pull"
        case .pullRequestMerged: return "arrow.triangle.merge"
        case .branch: return "arrow.triangle.branch"
        case .idle: return "circle.fill"
        case .pending: return "circle"
        }
    }

    /// The pure inputs, captured by the snapshot factory.
    struct Input: Equatable {
        struct PullRequest: Equatable {
            let label: String
            let number: Int
            let status: SidebarPullRequestStatus
        }

        /// Agent-owned status entries in display order.
        var agentEntries: [SidebarStatusEntry] = []
        /// Lifecycle states of the workspace's agents (manual loaders excluded).
        var lifecycleStates: [AgentHibernationLifecycleState] = []
        /// Whether the row already draws the animated loading spinner.
        var showsRunningSpinner = false
        var pullRequests: [PullRequest] = []
        var branch: String?
    }

    private static let tooltipFormat = String(
        localized: "sidebar.agentStatus.glyph.tooltip",
        defaultValue: "%1$@: %2$@"
    )

    static func resolve(_ input: Input) -> SidebarCompactStatusGlyph? {
        let kind: Kind
        if input.lifecycleStates.contains(.needsInput)
            || input.agentEntries.contains(where: Self.reportsError) {
            kind = .attention
        } else if input.showsRunningSpinner, input.lifecycleStates.contains(.running) {
            return nil
        } else if let pullRequest = input.pullRequests.first {
            switch pullRequest.status {
            case .open: kind = .pullRequestOpen
            case .merged: kind = .pullRequestMerged
            case .closed: kind = .pullRequestClosed
            }
        } else if input.branch != nil {
            kind = .branch
        } else if input.lifecycleStates.contains(.idle) {
            kind = .idle
        } else if !input.lifecycleStates.isEmpty || !input.agentEntries.isEmpty {
            kind = .pending
        } else {
            return nil
        }
        return SidebarCompactStatusGlyph(kind: kind, tooltip: tooltip(for: input))
    }

    /// Agent hooks mark failures with the warning-triangle icon.
    private static func reportsError(_ entry: SidebarStatusEntry) -> Bool {
        entry.icon?.contains("exclamationmark.triangle") == true
    }

    private static func tooltip(for input: Input) -> String {
        var lines = input.agentEntries.map {
            line(agentDisplayName(forStatusKey: $0.key), $0.value)
        }
        lines += input.pullRequests.map {
            line("\($0.label) #\($0.number)", pullRequestStatusText($0.status))
        }
        if let branch = input.branch {
            lines.append(branch)
        }
        return lines.joined(separator: "\n")
    }

    private static func line(_ name: String, _ value: String) -> String {
        String(format: tooltipFormat, locale: .current, name, value)
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

    /// Selected rows flatten the glyph to the selected foreground, like the
    /// metadata rows do, so colors never vanish into the selection fill.
    func color(isActive: Bool, selected: NSColor, secondary: NSColor) -> NSColor {
        if isActive { return selected }
        switch kind {
        case .attention: return .systemRed
        case .pullRequestOpen: return .systemGreen
        case .pullRequestMerged, .branch: return .systemPurple
        case .pullRequestClosed, .idle, .pending: return secondary
        }
    }
}

/// SwiftUI rendering for the default sidebar list. Takes resolved colors
/// only; no store access below the lazy-list boundary.
struct SidebarCompactStatusGlyphView: View {
    let glyph: SidebarCompactStatusGlyph?
    let pointSize: CGFloat
    let isActive: Bool
    let selectedColor: NSColor
    let secondaryColor: NSColor

    var body: some View {
        if let glyph {
            CmuxSystemSymbolImage(
                magnified: glyph.symbolName,
                pointSize: pointSize,
                weight: .semibold,
                tint: Color(nsColor: glyph.color(isActive: isActive, selected: selectedColor, secondary: secondaryColor))
            )
            .safeHelp(glyph.tooltip)
            .accessibilityLabel(glyph.tooltip)
        }
    }
}
