import CmuxFoundation
import SwiftUI

/// One horizontal grid for every Cloud row, so glyphs sit in a column and text
/// starts at the same offset whatever the row type. The outline reserves the
/// 16pt disclosure slot (`indentationPerLevel`) and the cell adds the 6pt gap
/// after it; per-variant metrics (row heights, fonts, icon slots) live in
/// ``CloudTreeStyle`` — only the fixed grid pieces stay here.
enum CloudTreeRowGrid {
    /// Width of the outline's disclosure slot; content starts `disclosureGap` after it.
    static let disclosureSlot: CGFloat = 16
    static let disclosureGap: CGFloat = 6
    /// Machine rows: the status dot has its own slot, never adjacent to the chevron.
    static let dotSlot: CGFloat = 10
    static let dotGap: CGFloat = 8
    /// Space between a title and its dim detail text.
    static let detailGap: CGFloat = 6
    /// Trailing accessories (open marker): gap after the text, a fixed slot, then padding.
    static let trailingGap: CGFloat = 10
    static let trailingSlot: CGFloat = 16
    static let trailingPadding: CGFloat = 8
    static let machineStatsLineHeight: CGFloat = 13
    static let machineLineSpacing: CGFloat = 1
}

/// Display-only SwiftUI content for one Cloud outline row, rendered in the
/// given ``CloudTreeStyle``. The hosting cell passes every pointer event
/// through to the outline (selection, drag, double-click, context menu), so
/// nothing here is interactive.
struct CloudTreeRowContentView: View {
    let kind: CloudTreeNode.Kind
    var style: CloudTreeStyle = CloudTreeStyleStore.current

    var body: some View {
        switch kind {
        case .machine(let machine, _):
            CloudTreeMachineRowContent(machine: machine, style: style)
        case .localMachine(let row):
            CloudTreeLocalMachineRowContent(row: row, style: style)
        case .terminalsPool(_, let count):
            groupRow(title: String(localized: "cloudTree.group.terminals", defaultValue: "Terminals"), count: count)
        case .displaysPool(_, let count):
            groupRow(title: String(localized: "cloudTree.group.displays", defaultValue: "Displays"), count: count)
        case .workspacesGroup:
            groupRow(title: String(localized: "cloudTree.group.workspaces", defaultValue: "Workspaces"))
        case .workspace(_, let workspace, let terminalCount):
            leafRow(icon: workspaceIcon) {
                Text(workspace.name)
                    .cmuxFont(size: style.titleSize, weight: workspace.focused ? .medium : .regular)
                    .foregroundStyle(.primary)
            } detail: {
                if style.showsGroupCounts {
                    Text(Self.count(terminalCount))
                        .cmuxFont(size: style.detailSize, monospacedDigit: true)
                        .foregroundStyle(.tertiary)
                }
            }
        case .localWorkspace(let row):
            leafRow(icon: workspaceIcon) {
                Text(row.title)
                    .cmuxFont(size: style.titleSize, weight: row.isSelected ? .medium : .regular)
                    .foregroundStyle(.primary)
            } detail: {
                if style.showsGroupCounts {
                    Text(Self.count(row.terminalCount))
                        .cmuxFont(size: style.detailSize, monospacedDigit: true)
                        .foregroundStyle(.tertiary)
                }
            }
        case .terminal(let row):
            CloudTreeTerminalRowContent(row: row, style: style)
        case .display(let resource):
            leafRow(icon: CloudTreeRowIcon(systemName: "display", style: iconStyle(tint: .teal), size: style.iconSize, slot: style.iconSlot)) {
                Text(resource.title.isEmpty ? String(localized: "cloudTree.node.desktop", defaultValue: "Desktop") : resource.title)
                    .cmuxFont(size: style.titleSize)
                    .foregroundStyle(.primary)
            } detail: {
                Text(String(localized: "cloudTree.node.desktop.detail", defaultValue: "noVNC"))
                    .cmuxFont(size: style.detailSize)
                    .foregroundStyle(.tertiary)
            }
        case .browsersGroup:
            groupRow(title: String(localized: "cloudTree.group.browsers", defaultValue: "Browsers"))
        case .browser(let row):
            CloudTreeBrowserRowContent(row: row, style: style)
        case .portsGroup:
            groupRow(title: String(localized: "cloudTree.group.ports", defaultValue: "Ports"))
        case .port(let resource):
            leafRow(icon: CloudTreeRowIcon(systemName: "network", style: iconStyle(tint: .secondary), size: style.iconSize, slot: style.iconSlot)) {
                Text(resource.port.map(String.init) ?? resource.title)
                    .cmuxFont(size: style.titleSize, monospacedDigit: true)
                    .foregroundStyle(.primary)
            } detail: {
                if let label = resource.detail, !label.isEmpty {
                    Text(label)
                        .cmuxFont(size: style.detailSize)
                        .foregroundStyle(.tertiary)
                }
            }
        case .placeholder(_, let placeholder):
            HStack(alignment: .firstTextBaseline, spacing: style.iconGap) {
                Group {
                    switch placeholder.style {
                    case .connecting:
                        ProgressView().controlSize(.mini)
                    case .error:
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: max(style.iconSize, 9), weight: .regular))
                            .foregroundStyle(.secondary)
                    case .dimmed:
                        Image(systemName: "moon.zzz")
                            .font(.system(size: max(style.iconSize, 9), weight: .regular))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: max(style.iconSlot, 12))
                Text(placeholder.text)
                    .cmuxFont(size: style.detailSize + 1)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.trailing, CloudTreeRowGrid.trailingPadding)
        }
    }

    /// Workspaces read as folders (the Finder metaphor); tinted variants get
    /// the sidebar's folder blue.
    private var workspaceIcon: CloudTreeRowIcon {
        CloudTreeRowIcon(systemName: "folder", style: iconStyle(tint: .blue), size: style.iconSize, slot: style.iconSlot)
    }

    private func iconStyle(tint: Color) -> AnyShapeStyle {
        style.iconTint == .tinted ? AnyShapeStyle(tint.opacity(0.85)) : AnyShapeStyle(.secondary)
    }

    /// A section label ("Terminals", "Workspaces"): dim text, no icon, but the
    /// icon slot stays reserved so the label lines up with its sibling rows'
    /// titles. Pools show their size as a dim count when the style wants it.
    private func groupRow(title: String, count: Int? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: style.iconGap) {
            if style.iconSlot > 0 {
                Color.clear.frame(width: style.iconSlot, height: 1)
            }
            HStack(alignment: .firstTextBaseline, spacing: CloudTreeRowGrid.detailGap) {
                Text(title)
                    .cmuxFont(size: style.groupLabelSize, weight: .medium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if style.showsGroupCounts, let count {
                    Text(String(count))
                        .cmuxFont(size: style.detailSize, monospacedDigit: true)
                        .foregroundStyle(.tertiary)
                }
            }
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
        HStack(alignment: .firstTextBaseline, spacing: style.iconGap) {
            if style.iconSlot > 0 {
                icon
            }
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

    static func count(_ terminals: Int) -> String {
        terminals == 1
            ? String(localized: "cloudTree.workspace.terminalCount.one", defaultValue: "1 terminal")
            : String(format: String(localized: "cloudTree.workspace.terminalCount.other", defaultValue: "%d terminals"), terminals)
    }
}

/// A row glyph centered in the shared icon slot.
struct CloudTreeRowIcon: View {
    let systemName: String
    let style: AnyShapeStyle
    var size: CGFloat = 10
    var slot: CGFloat = 16

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(style)
            .frame(width: slot, alignment: .center)
    }
}

/// A cmux-tui terminal row: lifecycle glyph, title (a dim sparkle prefix when an
/// agent is running in it), dimmed cwd, an optional daemon-tab badge on pool
/// rows, and a dim "open" mark at the trailing edge when a local pane is
/// already showing it. Monochrome like the Files tree: the lifecycle reads from
/// the glyph shape and text weight, not from color.
struct CloudTreeTerminalRowContent: View {
    let row: CloudTreeTerminalRow
    var style: CloudTreeStyle = CloudTreeStyleStore.current

    private var terminal: SurfaceResource { row.resource }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: style.iconGap) {
            if style.iconSlot > 0 {
                CloudTreeRowIcon(
                    systemName: glyph,
                    style: terminal.lifecycle == .exited ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary),
                    size: style.iconSize,
                    slot: style.iconSlot
                )
            }
            HStack(alignment: .firstTextBaseline, spacing: CloudTreeRowGrid.detailGap) {
                if let agent = agentLabel {
                    Image(systemName: "sparkle")
                        .font(.system(size: max(style.iconSize - 1, 8), weight: .regular))
                        .foregroundStyle(.secondary)
                        .help(agent)
                }
                Text(terminal.title.isEmpty ? String(localized: "cloudTree.terminal.untitled", defaultValue: "terminal") : terminal.title)
                    .cmuxFont(size: style.titleSize)
                    .foregroundStyle(terminal.lifecycle == .exited ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let cwd = terminal.detail, !cwd.isEmpty {
                    Text(Self.abbreviated(cwd))
                        .cmuxFont(size: style.detailSize)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: CloudTreeRowGrid.trailingGap)
            if style.showsViewBadges, let views = row.viewBadge {
                // Pool rows: how many daemon tabs show this terminal. 0 reads as
                // "detached — alive with no view", the pool's whole point.
                Text(String(views))
                    .cmuxFont(size: style.detailSize, monospacedDigit: true)
                    .foregroundStyle(.tertiary)
                    .frame(width: CloudTreeRowGrid.trailingSlot, alignment: .center)
                    .help(Self.viewsHelp(views))
            }
            if row.isOpen {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .frame(width: CloudTreeRowGrid.trailingSlot, alignment: .center)
                    .help(String(localized: "cloudTree.terminal.open", defaultValue: "Open in a pane"))
            }
        }
        .padding(.trailing, CloudTreeRowGrid.trailingPadding)
    }

    static func viewsHelp(_ views: Int) -> String {
        switch views {
        case 0: return String(localized: "cloudTree.terminal.views.zero", defaultValue: "No tabs on the machine show this terminal")
        case 1: return String(localized: "cloudTree.terminal.views.one", defaultValue: "1 tab on the machine shows this terminal")
        default: return String(format: String(localized: "cloudTree.terminal.views.other", defaultValue: "%d tabs on the machine show this terminal"), views)
        }
    }

    private var glyph: String {
        switch terminal.lifecycle {
        case .launching, .running: return "terminal"
        case .exited: return "xmark.rectangle"
        case .unavailable: return "terminal"
        }
    }

    /// "source · state" for the tooltip; nil when no agent is attached.
    private var agentLabel: String? {
        guard let agent = terminal.agent else { return nil }
        let source = agent.source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state = agent.state.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty, state.isEmpty { return nil }
        if !source.isEmpty, !state.isEmpty { return "\(source) · \(state)" }
        return source.isEmpty ? state : source
    }

    static func abbreviated(_ path: String) -> String {
        if path == "/root" { return "~" }
        if path.hasPrefix("/root/") { return "~" + path.dropFirst("/root".count) }
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            if path == home { return "~" }
            if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        }
        return path
    }
}

/// A browser row: globe glyph, page title, dim URL host, and the open mark.
struct CloudTreeBrowserRowContent: View {
    let row: CloudTreeBrowserRow
    var style: CloudTreeStyle = CloudTreeStyleStore.current

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: style.iconGap) {
            if style.iconSlot > 0 {
                CloudTreeRowIcon(
                    systemName: "globe",
                    style: style.iconTint == .tinted ? AnyShapeStyle(Color.blue.opacity(0.85)) : AnyShapeStyle(.secondary),
                    size: style.iconSize,
                    slot: style.iconSlot
                )
            }
            HStack(alignment: .firstTextBaseline, spacing: CloudTreeRowGrid.detailGap) {
                Text(row.resource.title.isEmpty ? String(localized: "cloudTree.browser.untitled", defaultValue: "browser") : row.resource.title)
                    .cmuxFont(size: style.titleSize)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail = Self.detail(for: row) {
                    Text(detail)
                        .cmuxFont(size: style.detailSize)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: CloudTreeRowGrid.trailingGap)
            if row.isOpen {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .frame(width: CloudTreeRowGrid.trailingSlot, alignment: .center)
                    .help(String(localized: "cloudTree.terminal.open", defaultValue: "Open in a pane"))
            }
        }
        .padding(.trailing, CloudTreeRowGrid.trailingPadding)
    }

    /// The URL's host (or the local workspace showing it) as the dim detail.
    static func detail(for row: CloudTreeBrowserRow) -> String? {
        if let url = row.resource.url, let host = URL(string: url)?.host, !host.isEmpty { return host }
        return row.workspaceTitle
    }
}

/// This Mac's header row, on the same grid as the cloud machine row. Single- or
/// two-line per the style; no status dot (the local machine needs no link).
struct CloudTreeLocalMachineRowContent: View {
    let row: CloudTreeLocalMachineRow
    var style: CloudTreeStyle = CloudTreeStyleStore.current

    var body: some View {
        switch style.machineRowLayout {
        case .singleLine:
            HStack(alignment: .firstTextBaseline, spacing: CloudTreeRowGrid.dotGap) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: max(style.iconSize, 9), weight: .regular))
                    .foregroundStyle(style.iconTint == .tinted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: CloudTreeRowGrid.dotSlot, alignment: .center)
                Text(row.name)
                    .cmuxFont(size: style.machineNameSize, weight: .medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: CloudTreeRowGrid.trailingGap)
            }
            .padding(.trailing, CloudTreeRowGrid.trailingPadding)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.name)
        case .twoLine:
            HStack(alignment: .top, spacing: CloudTreeRowGrid.dotGap) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: CloudTreeRowGrid.dotSlot, height: style.machineNameLineHeight, alignment: .center)
                VStack(alignment: .leading, spacing: CloudTreeRowGrid.machineLineSpacing) {
                    Text(row.name)
                        .cmuxFont(size: style.machineNameSize, weight: .medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: style.machineNameLineHeight)
                    Text(Self.summary(row))
                        .cmuxFont(size: style.detailSize + 0.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: style.machineSubtitleLineHeight)
                }
                Spacer(minLength: CloudTreeRowGrid.trailingGap)
            }
            .padding(.vertical, style.machineVerticalPadding)
            .padding(.trailing, CloudTreeRowGrid.trailingPadding)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.name)
        }
    }

    /// "3 terminals · 1 browser"
    static func summary(_ row: CloudTreeLocalMachineRow) -> String {
        var parts = [CloudTreeRowContentView.count(row.terminalCount)]
        if row.browserCount > 0 {
            parts.append(
                row.browserCount == 1
                    ? String(localized: "cloudTree.local.browserCount.one", defaultValue: "1 browser")
                    : String(format: String(localized: "cloudTree.local.browserCount.other", defaultValue: "%d browsers"), row.browserCount)
            )
        }
        return parts.joined(separator: " · ")
    }
}

/// The machine row's display content: activity dot, name, and — in the two-line
/// layout — subtitle plus optional stats. Hover buttons and menus live in the
/// outline cell, and double-click in the outline.
struct CloudTreeMachineRowContent: View {
    let machine: MachineSnapshot
    var style: CloudTreeStyle = CloudTreeStyleStore.current

    var body: some View {
        switch style.machineRowLayout {
        case .singleLine:
            // Finder-like: dot, name, one dim inline fact. Everything else is
            // in the tooltip and the context menu.
            HStack(alignment: .firstTextBaseline, spacing: CloudTreeRowGrid.dotGap) {
                activityDot
                    .frame(width: CloudTreeRowGrid.dotSlot, alignment: .center)
                Text(machine.displayName)
                    .cmuxFont(size: style.machineNameSize, weight: .medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let fact = Self.inlineFact(machine) {
                    Text(fact)
                        .cmuxFont(size: style.detailSize)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: CloudTreeRowGrid.trailingGap)
            }
            .padding(.trailing, CloudTreeRowGrid.trailingPadding)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(machine.displayName), \(machine.activityLabel)")
        case .twoLine:
            // Top-aligned: the dot and the outline's chevron both sit on the name line
            // (see `CloudTreeNSOutlineView.frameOfOutlineCell`), not on the row's middle.
            HStack(alignment: .top, spacing: CloudTreeRowGrid.dotGap) {
                activityDot
                    .frame(width: CloudTreeRowGrid.dotSlot, height: style.machineNameLineHeight, alignment: .center)
                VStack(alignment: .leading, spacing: CloudTreeRowGrid.machineLineSpacing) {
                    Text(machine.displayName)
                        .cmuxFont(size: style.machineNameSize, weight: .medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: style.machineNameLineHeight)
                    Text(Self.subtitle(machine))
                        .cmuxFont(size: style.detailSize + 0.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: style.machineSubtitleLineHeight)
                    if style.showsMachineStats, let stats = machine.stats, let line = Self.statsLine(stats) {
                        // One dim line instead of colored gauges: the numbers carry the
                        // information; color would only compete with the status dot.
                        Text(line)
                            .cmuxFont(size: style.detailSize, monospacedDigit: true)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(height: CloudTreeRowGrid.machineStatsLineHeight)
                    }
                }
                Spacer(minLength: CloudTreeRowGrid.trailingGap)
            }
            .padding(.vertical, style.machineVerticalPadding)
            .padding(.trailing, CloudTreeRowGrid.trailingPadding)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(machine.displayName), \(machine.activityLabel)")
        }
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

    /// The two-line layout's second line. Deliberately excludes the free-access
    /// countdown: expiry is plan chrome (the panel header owns it), not a fact
    /// about the machine. "Locked" stays — it explains a dead machine row.
    static func subtitle(_ machine: MachineSnapshot) -> String {
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
        if machine.freeAccess == .expired {
            parts.append(String(localized: "machines.row.locked", defaultValue: "Locked"))
        }
        return parts.joined(separator: " · ")
    }

    /// The single-line layout's one dim fact: "Locked" when expired, else nothing.
    static func inlineFact(_ machine: MachineSnapshot) -> String? {
        machine.freeAccess == .expired
            ? String(localized: "machines.row.locked", defaultValue: "Locked")
            : nil
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
