import CmuxFoundation
import SwiftUI

/// Display-only SwiftUI content for one Cloud outline row. The hosting cell
/// passes every pointer event through to the outline (selection, drag,
/// double-click, context menu), so nothing here is interactive.
struct CloudTreeRowContentView: View {
    let kind: CloudTreeNode.Kind

    var body: some View {
        switch kind {
        case .machine(let machine):
            CloudTreeMachineRowContent(machine: machine)
        case .workspacesGroup:
            groupRow(
                symbol: "square.stack.3d.up",
                title: String(localized: "cloudTree.group.workspaces", defaultValue: "Workspaces")
            )
        case .workspace(_, let workspace):
            HStack(spacing: 6) {
                Image(systemName: workspace.focused ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.8))
                    .frame(width: 14)
                Text(workspace.name)
                    .cmuxFont(size: 12)
                    .foregroundColor(.primary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Self.count(workspace.terminals.count))
                    .cmuxFont(size: 10.5, monospacedDigit: true)
                    .foregroundColor(.secondary.opacity(0.6))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
        case .terminal(_, let terminal):
            CloudTreeTerminalRowContent(terminal: terminal)
        case .desktop:
            HStack(spacing: 6) {
                Image(systemName: "display")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.8))
                    .frame(width: 14)
                Text(String(localized: "cloudTree.node.desktop", defaultValue: "Desktop"))
                    .cmuxFont(size: 12)
                    .foregroundColor(.primary.opacity(0.9))
                Text(String(localized: "cloudTree.node.desktop.detail", defaultValue: "noVNC screen"))
                    .cmuxFont(size: 10.5)
                    .foregroundColor(.secondary.opacity(0.6))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        case .portsGroup:
            groupRow(
                symbol: "network",
                title: String(localized: "cloudTree.group.ports", defaultValue: "Ports")
            )
        case .port(_, let port):
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.8))
                    .frame(width: 14)
                Text(String(port.port))
                    .cmuxFont(size: 12, monospacedDigit: true)
                    .foregroundColor(.primary.opacity(0.9))
                if let label = port.label, !label.isEmpty {
                    Text(label)
                        .cmuxFont(size: 10.5)
                        .foregroundColor(.secondary.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
        case .placeholder(_, let placeholder):
            HStack(spacing: 6) {
                switch placeholder.style {
                case .connecting:
                    ProgressView().controlSize(.mini)
                case .error:
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.orange.opacity(0.9))
                case .dimmed:
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                Text(placeholder.text)
                    .cmuxFont(size: 11.5)
                    .foregroundColor(placeholder.style == .error ? .orange.opacity(0.9) : .secondary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
    }

    private func groupRow(symbol: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary.opacity(0.7))
                .frame(width: 14)
            Text(title)
                .cmuxFont(size: 11, weight: .semibold)
                .foregroundColor(.secondary.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private static func count(_ terminals: Int) -> String {
        terminals == 1
            ? String(localized: "cloudTree.workspace.terminalCount.one", defaultValue: "1 terminal")
            : String(format: String(localized: "cloudTree.workspace.terminalCount.other", defaultValue: "%d terminals"), terminals)
    }
}

/// A cmux-tui terminal row: lifecycle glyph, title, dimmed cwd, agent badge,
/// and an "open" mark when a local pane is already showing it.
struct CloudTreeTerminalRowContent: View {
    let terminal: CloudTreeTerminal

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: glyph)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(glyphColor)
                .frame(width: 14)
            Text(terminal.title.isEmpty ? String(localized: "cloudTree.terminal.untitled", defaultValue: "terminal") : terminal.title)
                .cmuxFont(size: 12)
                .foregroundColor(terminal.lifecycle == .exited ? .secondary.opacity(0.7) : .primary.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
            if let cwd = terminal.cwd, !cwd.isEmpty {
                Text(Self.abbreviated(cwd))
                    .cmuxFont(size: 10.5)
                    .foregroundColor(.secondary.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let agent = terminal.agentSource ?? terminal.agentState, !agent.isEmpty {
                Text(agentBadge)
                    .cmuxFont(size: 9.5, weight: .semibold)
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .lineLimit(1)
                    .fixedSize()
                    .help(agent)
            }
            if terminal.openSurfaceID != nil {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.7))
                    .help(String(localized: "cloudTree.terminal.open", defaultValue: "Open in a pane"))
            }
        }
    }

    private var glyph: String {
        switch terminal.lifecycle {
        case .launching: return "terminal"
        case .running: return "terminal.fill"
        case .exited: return "xmark.rectangle"
        }
    }

    private var glyphColor: Color {
        switch terminal.lifecycle {
        case .launching: return .secondary.opacity(0.6)
        case .running: return .green.opacity(0.85)
        case .exited: return .secondary.opacity(0.5)
        }
    }

    private var agentBadge: String {
        let source = terminal.agentSource?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state = terminal.agentState?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !source.isEmpty, !state.isEmpty { return "\(source) · \(state)" }
        return source.isEmpty ? state : source
    }

    static func abbreviated(_ path: String) -> String {
        if path == "/root" { return "~" }
        if path.hasPrefix("/root/") { return "~" + path.dropFirst("/root".count) }
        return path
    }
}

/// The machine row's display content: activity dot, name, subtitle, gauges.
/// Ported from the former flat `MachineRow`; hover buttons and menus live in
/// the outline cell, and double-click in the outline.
struct CloudTreeMachineRowContent: View {
    let machine: MachineSnapshot

    var body: some View {
        HStack(spacing: 8) {
            activityDot
            VStack(alignment: .leading, spacing: 1) {
                Text(machine.displayName)
                    .cmuxFont(size: 13)
                    .foregroundColor(.primary.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    // A box's type at a glance: a desktop machine has its screen,
                    // a base machine is shell-only.
                    Image(systemName: machine.isDesktop ? "display" : "terminal")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text(subtitle)
                        .cmuxFont(size: 11)
                        .foregroundColor(.secondary.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let stats = machine.stats {
                    MachineStatsLine(stats: stats)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(machine.displayName), \(machine.activityLabel)")
    }

    @ViewBuilder
    private var activityDot: some View {
        if machine.freeAccess == .expired {
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.8))
                .frame(width: 7)
        } else {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
        }
    }

    private var dotColor: Color {
        switch machine.activity {
        case .ready: return Color.green.opacity(0.85)
        case .pending: return Color.orange.opacity(0.9)
        case .attention: return Color.red.opacity(0.85)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if machine.label?.isEmpty == false {
            // Labeled machines keep their address visible: the id is what CLI
            // verbs and URLs use.
            parts.append(machine.id)
        }
        parts.append(machine.kindLabel)
        if let createdAt = machine.createdAt {
            parts.append(Self.relativeFormatter.localizedString(for: createdAt, relativeTo: Date()))
        }
        switch machine.freeAccess {
        case .unrestricted:
            break
        case .expired:
            parts.append(String(localized: "machines.row.locked", defaultValue: "Locked"))
        case .active(let daysLeft):
            parts.append(
                daysLeft == 1
                    ? String(localized: "machines.row.dayLeft", defaultValue: "1 day left")
                    : String(format: String(localized: "machines.row.daysLeft", defaultValue: "%d days left"), daysLeft)
            )
        }
        return parts.joined(separator: " · ")
    }

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

/// The machine row's hover verbs (desktop + delete). Interactive, so it lives
/// in its own hit-testable host beside the pass-through display content.
struct CloudTreeMachineRowButtons: View {
    let machine: MachineSnapshot
    let actions: MachineRowActions

    var body: some View {
        HStack(spacing: 2) {
            if machine.isDesktop {
                MachinesChromeIconButton(
                    symbolName: "display",
                    accessibilityLabel: String(localized: "machines.row.openDesktop", defaultValue: "Open Desktop"),
                    isBusy: false
                ) {
                    actions.openDesktop(machine.id)
                }
            }
            MachinesChromeIconButton(
                symbolName: "trash",
                accessibilityLabel: String(localized: "machines.row.delete", defaultValue: "Delete Machine"),
                isBusy: false
            ) {
                actions.confirmDelete(machine.id)
            }
        }
    }
}
