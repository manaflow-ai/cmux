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
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(workspace.name)
                    .cmuxFont(size: 12, weight: workspace.focused ? .medium : .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Self.count(workspace.terminals.count))
                    .cmuxFont(size: 10.5, monospacedDigit: true)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
        case .terminal(_, let terminal):
            CloudTreeTerminalRowContent(terminal: terminal)
        case .desktop:
            HStack(spacing: 6) {
                Image(systemName: "display")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(String(localized: "cloudTree.node.desktop", defaultValue: "Desktop"))
                    .cmuxFont(size: 12)
                    .foregroundStyle(.primary)
                Text(String(localized: "cloudTree.node.desktop.detail", defaultValue: "noVNC screen"))
                    .cmuxFont(size: 10.5)
                    .foregroundStyle(.tertiary)
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
                Image(systemName: "network")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(String(port.port))
                    .cmuxFont(size: 12, monospacedDigit: true)
                    .foregroundStyle(.primary)
                if let label = port.label, !label.isEmpty {
                    Text(label)
                        .cmuxFont(size: 10.5)
                        .foregroundStyle(.tertiary)
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
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)
                case .dimmed:
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
                Text(placeholder.text)
                    .cmuxFont(size: 11.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
    }

    /// A section label ("Workspaces", "Ports"): dim text only, hierarchy comes
    /// from the indentation and weight, not from color or an icon.
    private func groupRow(symbol: String, title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .cmuxFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
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

/// A cmux-tui terminal row: lifecycle glyph, title (a dim sparkle prefix when an
/// agent is running in it), dimmed cwd, and a dim "open" mark at the trailing
/// edge when a local pane is already showing it. Monochrome like the Files tree:
/// the lifecycle reads from the glyph shape and text weight, not from color.
struct CloudTreeTerminalRowContent: View {
    let terminal: CloudTreeTerminal

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: glyph)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(terminal.lifecycle == .exited ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .frame(width: 14)
            if let agent = agentLabel {
                Image(systemName: "sparkle")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.secondary)
                    .help(agent)
            }
            Text(terminal.title.isEmpty ? String(localized: "cloudTree.terminal.untitled", defaultValue: "terminal") : terminal.title)
                .cmuxFont(size: 12)
                .foregroundStyle(terminal.lifecycle == .exited ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
            if let cwd = terminal.cwd, !cwd.isEmpty {
                Text(Self.abbreviated(cwd))
                    .cmuxFont(size: 10.5)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if terminal.openSurfaceID != nil {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .help(String(localized: "cloudTree.terminal.open", defaultValue: "Open in a pane"))
            }
        }
    }

    private var glyph: String {
        switch terminal.lifecycle {
        case .launching: return "terminal"
        case .running: return "terminal"
        case .exited: return "xmark.rectangle"
        }
    }

    /// "source · state" for the tooltip; nil when no agent is attached.
    private var agentLabel: String? {
        let source = terminal.agentSource?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state = terminal.agentState?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if source.isEmpty, state.isEmpty { return nil }
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
                    .cmuxFont(size: 12.5, weight: .medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let stats = machine.stats, let line = Self.statsLine(stats) {
                    // One dim line instead of colored gauges: the numbers carry the
                    // information; color would only compete with the status dot.
                    Text(line)
                        .cmuxFont(size: 10.5, monospacedDigit: true)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
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
                .foregroundStyle(.secondary)
                .frame(width: 7)
        } else {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
        }
    }

    /// The one colored element in the tree: the sidebar's semantic status colors
    /// (running, pending, needs attention), so a glance still answers "is it up".
    private var dotColor: Color {
        switch machine.activity {
        case .ready: return Color.green.opacity(0.85)
        case .pending: return Color.orange.opacity(0.9)
        case .attention: return Color.red.opacity(0.85)
        }
    }

    /// "CPU 9% · Mem 3.4/3.8 GB · Disk 2.8/3.1 GB" for an awake machine, the
    /// asleep line otherwise; nil when there is nothing to say yet.
    static func statsLine(_ stats: VMStats) -> String? {
        switch stats.state {
        case .awake:
            var parts: [String] = []
            if let cpu = stats.cpuPercent {
                parts.append(String(format: String(localized: "cloudTree.stats.cpu", defaultValue: "CPU %d%%"), Int(cpu.rounded())))
            }
            if let used = stats.memoryUsedMb, let total = stats.memoryTotalMb, total > 0 {
                parts.append(String(format: String(localized: "cloudTree.stats.memory", defaultValue: "Mem %@/%@ GB"), gb(used), gb(total)))
            }
            if let used = stats.diskUsedMb, let total = stats.diskTotalMb, total > 0 {
                parts.append(String(format: String(localized: "cloudTree.stats.disk", defaultValue: "Disk %@/%@ GB"), gb(used), gb(total)))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .asleep:
            return String(localized: "machines.stats.asleep", defaultValue: "Asleep \u{00B7} free while it sleeps")
        case .unknown:
            return nil
        }
    }

    private static func gb(_ mb: Int) -> String {
        let value = Double(mb) / 1024
        return value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
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
