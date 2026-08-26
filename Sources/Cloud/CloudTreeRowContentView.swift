import CmuxFoundation
import SwiftUI

/// One horizontal grid for every Cloud row, so glyphs sit in a column and text
/// starts at the same offset whatever the row type. The outline reserves the
/// 16pt disclosure slot (`indentationPerLevel`) and the cell adds the 6pt gap
/// after it; the rest lives here.
enum CloudTreeRowGrid {
    /// Width of the outline's disclosure slot; content starts `disclosureGap` after it.
    static let disclosureSlot: CGFloat = 16
    static let disclosureGap: CGFloat = 6
    /// Every row reserves this slot for its glyph (empty on section rows) so titles align.
    static let iconSlot: CGFloat = 16
    static let iconGap: CGFloat = 8
    /// Machine rows: the status dot has its own slot, never adjacent to the chevron.
    static let dotSlot: CGFloat = 10
    static let dotGap: CGFloat = 8
    /// Space between a title and its dim detail text.
    static let detailGap: CGFloat = 6
    /// Trailing accessories (open marker): gap after the text, a fixed slot, then padding.
    static let trailingGap: CGFloat = 10
    static let trailingSlot: CGFloat = 16
    static let trailingPadding: CGFloat = 8
    /// Vertical rhythm.
    static let rowHeight: CGFloat = 24
    static let machineVerticalPadding: CGFloat = 4
    /// The machine name line (12.5pt medium); the disclosure chevron centers on it.
    static let machineNameLineHeight: CGFloat = 16
    static let machineSubtitleLineHeight: CGFloat = 14
    static let machineStatsLineHeight: CGFloat = 13
    static let machineLineSpacing: CGFloat = 1

    static func machineRowHeight(hasStats: Bool) -> CGFloat {
        let lines = machineNameLineHeight + machineLineSpacing + machineSubtitleLineHeight
            + (hasStats ? machineLineSpacing + machineStatsLineHeight : 0)
        return machineVerticalPadding * 2 + lines
    }
}

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
            groupRow(title: String(localized: "cloudTree.group.workspaces", defaultValue: "Workspaces"))
        case .workspace(_, let workspace):
            leafRow(icon: CloudTreeRowIcon(systemName: "rectangle.split.2x1", style: AnyShapeStyle(.secondary))) {
                Text(workspace.name)
                    .cmuxFont(size: 12, weight: workspace.focused ? .medium : .regular)
                    .foregroundStyle(.primary)
            } detail: {
                Text(Self.count(workspace.terminals.count))
                    .cmuxFont(size: 10.5, monospacedDigit: true)
                    .foregroundStyle(.tertiary)
            }
        case .terminal(_, let terminal):
            CloudTreeTerminalRowContent(terminal: terminal)
        case .desktop:
            leafRow(icon: CloudTreeRowIcon(systemName: "display", style: AnyShapeStyle(.secondary))) {
                Text(String(localized: "cloudTree.node.desktop", defaultValue: "Desktop"))
                    .cmuxFont(size: 12)
                    .foregroundStyle(.primary)
            } detail: {
                Text(String(localized: "cloudTree.node.desktop.detail", defaultValue: "noVNC screen"))
                    .cmuxFont(size: 10.5)
                    .foregroundStyle(.tertiary)
            }
        case .portsGroup:
            groupRow(title: String(localized: "cloudTree.group.ports", defaultValue: "Ports"))
        case .port(_, let port):
            leafRow(icon: CloudTreeRowIcon(systemName: "network", style: AnyShapeStyle(.secondary))) {
                Text(String(port.port))
                    .cmuxFont(size: 12, monospacedDigit: true)
                    .foregroundStyle(.primary)
            } detail: {
                if let label = port.label, !label.isEmpty {
                    Text(label)
                        .cmuxFont(size: 10.5)
                        .foregroundStyle(.tertiary)
                }
            }
        case .placeholder(_, let placeholder):
            HStack(alignment: .firstTextBaseline, spacing: CloudTreeRowGrid.iconGap) {
                Group {
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
                }
                .frame(width: CloudTreeRowGrid.iconSlot)
                Text(placeholder.text)
                    .cmuxFont(size: 11.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.trailing, CloudTreeRowGrid.trailingPadding)
        }
    }

    /// A section label ("Workspaces", "Ports"): dim text, no icon, but the icon
    /// slot stays reserved so the label lines up with its sibling rows' titles.
    private func groupRow(title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CloudTreeRowGrid.iconGap) {
            Color.clear.frame(width: CloudTreeRowGrid.iconSlot, height: 1)
            Text(title)
                .cmuxFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.trailing, CloudTreeRowGrid.trailingPadding)
    }

    /// glyph slot → title → dim detail, on one baseline.
    private func leafRow<Title: View, Detail: View>(
        icon: CloudTreeRowIcon,
        @ViewBuilder title: () -> Title,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CloudTreeRowGrid.iconGap) {
            icon
            HStack(alignment: .firstTextBaseline, spacing: CloudTreeRowGrid.detailGap) {
                title()
                    .lineLimit(1)
                    .truncationMode(.tail)
                detail()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, CloudTreeRowGrid.trailingPadding)
    }

    private static func count(_ terminals: Int) -> String {
        terminals == 1
            ? String(localized: "cloudTree.workspace.terminalCount.one", defaultValue: "1 terminal")
            : String(format: String(localized: "cloudTree.workspace.terminalCount.other", defaultValue: "%d terminals"), terminals)
    }
}

/// A row glyph centered in the shared icon slot.
struct CloudTreeRowIcon: View {
    let systemName: String
    let style: AnyShapeStyle

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(style)
            .frame(width: CloudTreeRowGrid.iconSlot, alignment: .center)
    }
}

/// A cmux-tui terminal row: lifecycle glyph, title (a dim sparkle prefix when an
/// agent is running in it), dimmed cwd, and a dim "open" mark at the trailing
/// edge when a local pane is already showing it. Monochrome like the Files tree:
/// the lifecycle reads from the glyph shape and text weight, not from color.
struct CloudTreeTerminalRowContent: View {
    let terminal: CloudTreeTerminal

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CloudTreeRowGrid.iconGap) {
            CloudTreeRowIcon(
                systemName: glyph,
                style: terminal.lifecycle == .exited ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary)
            )
            HStack(alignment: .firstTextBaseline, spacing: CloudTreeRowGrid.detailGap) {
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
            }
            Spacer(minLength: CloudTreeRowGrid.trailingGap)
            if terminal.openSurfaceID != nil {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .frame(width: CloudTreeRowGrid.trailingSlot, alignment: .center)
                    .help(String(localized: "cloudTree.terminal.open", defaultValue: "Open in a pane"))
            }
        }
        .padding(.trailing, CloudTreeRowGrid.trailingPadding)
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
        // Top-aligned: the dot and the outline's chevron both sit on the name line
        // (see `CloudTreeNSOutlineView.frameOfOutlineCell`), not on the row's middle.
        HStack(alignment: .top, spacing: CloudTreeRowGrid.dotGap) {
            activityDot
                .frame(width: CloudTreeRowGrid.dotSlot, height: CloudTreeRowGrid.machineNameLineHeight, alignment: .center)
            VStack(alignment: .leading, spacing: CloudTreeRowGrid.machineLineSpacing) {
                Text(machine.displayName)
                    .cmuxFont(size: 12.5, weight: .medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: CloudTreeRowGrid.machineNameLineHeight)
                Text(subtitle)
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: CloudTreeRowGrid.machineSubtitleLineHeight)
                if let stats = machine.stats, let line = Self.statsLine(stats) {
                    // One dim line instead of colored gauges: the numbers carry the
                    // information; color would only compete with the status dot.
                    Text(line)
                        .cmuxFont(size: 10.5, monospacedDigit: true)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: CloudTreeRowGrid.machineStatsLineHeight)
                }
            }
            Spacer(minLength: CloudTreeRowGrid.trailingGap)
        }
        .padding(.vertical, CloudTreeRowGrid.machineVerticalPadding)
        .padding(.trailing, CloudTreeRowGrid.trailingPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(machine.displayName), \(machine.activityLabel)")
    }

    @ViewBuilder
    private var activityDot: some View {
        if machine.freeAccess == .expired {
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
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
        HStack(spacing: 4) {
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
