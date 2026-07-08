import AppKit
import CmuxFoundation
import CmuxSidebar
import SwiftUI

/// Below-card presentation of the per-agent rows. Owns the variant switch for
/// every below-card style; renders nothing when an in-card or global variant
/// is active. Rows receive immutable value snapshots and closure action
/// bundles only, per the sidebar list snapshot-boundary rule (the variant
/// store is a deliberate, temporary debug-lab exception; it changes only on
/// explicit user picks).
struct SidebarAgentStatusRows: View {
    let rows: [SidebarAgentStatusRow]
    let fontScale: CGFloat
    let onFocus: () -> Void
    let onFocusPanel: (UUID) -> Void

    @ObservedObject private var variantStore = SidebarAgentRowsVariantStore.shared
    @State private var isCollapsed = false

    var body: some View {
        switch variantStore.variant {
        case .belowAccordion:
            VStack(alignment: .leading, spacing: 2) {
                if rows.count > 1 {
                    accordionHeader
                    if !isCollapsed {
                        rowList(layout: .nameFirst)
                    }
                } else {
                    rowList(layout: .nameFirst)
                }
            }
        case .belowFlat:
            VStack(alignment: .leading, spacing: 2) {
                rowList(layout: .nameFirst)
            }
        case .belowTree:
            VStack(alignment: .leading, spacing: 0) {
                rowList(layout: .tree)
            }
        case .belowChips:
            SidebarAgentChipsFlow(rows: rows, fontScale: fontScale, onFocusPanel: onFocusPanel)
        case .graphite, .inCardRows, .inCardCompact, .globalSection:
            EmptyView()
        }
    }

    @ViewBuilder
    private func rowList(layout: SidebarAgentRowLayout) -> some View {
        ForEach(rows) { row in
            SidebarAgentStatusEntryRowView(
                row: row,
                fontScale: fontScale,
                layout: layout,
                onFocusPanel: onFocusPanel
            )
        }
    }

    private var accordionHeader: some View {
        let summary = SidebarAgentStatusRowsSummary(rows: rows)
        return Button {
            onFocus()
            withAnimation(.easeInOut(duration: 0.15)) {
                isCollapsed.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                CmuxSystemSymbolImage(
                    magnified: isCollapsed ? "chevron.right" : "chevron.down",
                    pointSize: 7 * fontScale,
                    weight: .semibold
                )
                .foregroundColor(.secondary.opacity(0.8))
                if isCollapsed, let accent = summary.accentColorHex, let color = Color(hex: accent) {
                    Circle()
                        .fill(color)
                        .frame(width: 5 * fontScale, height: 5 * fontScale)
                }
                Text(summary.text)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .cmuxFont(size: 10 * fontScale, weight: .semibold)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .safeHelp(summary.text)
    }
}

/// In-card presentation (variants `inCardRows` / `inCardCompact`), mounted
/// inside the workspace card so it inherits the selection background. Renders
/// nothing for the below-card and global variants.
struct SidebarAgentStatusInCardRows: View {
    let rows: [SidebarAgentStatusRow]
    let activePanelId: UUID?
    let isActive: Bool
    let activeForegroundColor: Color
    let fontScale: CGFloat
    let onFocus: () -> Void
    let onFocusPanel: (UUID) -> Void

    @ObservedObject private var variantStore = SidebarAgentRowsVariantStore.shared

    var body: some View {
        switch variantStore.variant {
        case .graphite:
            SidebarAgentStatusGraphiteRows(
                rows: rows,
                activePanelId: activePanelId,
                isActive: isActive,
                activeForegroundColor: activeForegroundColor,
                fontScale: fontScale,
                onFocus: onFocus,
                onFocusPanel: onFocusPanel
            )
        case .inCardRows:
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    SidebarAgentStatusEntryRowView(
                        row: row,
                        fontScale: fontScale,
                        layout: .inCard(isActive: isActive, activeForeground: activeForegroundColor),
                        onFocusPanel: onFocusPanel
                    )
                }
            }
        case .inCardCompact:
            compactLine
        case .belowAccordion, .belowFlat, .belowTree, .belowChips, .globalSection:
            EmptyView()
        }
    }

    private var compactLine: some View {
        let summary = SidebarAgentStatusRowsSummary(rows: rows)
        return HStack(spacing: 5) {
            ForEach(rows) { row in
                Button {
                    onFocusPanel(row.panelId)
                } label: {
                    HStack(spacing: 2) {
                        SidebarAgentBrandIcon(row: row, fontScale: fontScale)
                        if let color = SidebarAgentRowStateStyle.stateColor(for: row) {
                            Circle()
                                .fill(color)
                                .frame(width: 4.5 * fontScale, height: 4.5 * fontScale)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .safeHelp(rowTooltip(row))
            }
            Text(summary.text)
                .cmuxFont(size: 9 * fontScale)
                .foregroundColor(isActive ? activeForegroundColor.opacity(0.7) : .secondary.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func rowTooltip(_ row: SidebarAgentStatusRow) -> String {
        [row.paneLabel, row.value].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Wrapping chips variant: one capsule per agent, border tinted by state.
struct SidebarAgentChipsFlow: View {
    let rows: [SidebarAgentStatusRow]
    let fontScale: CGFloat
    let onFocusPanel: (UUID) -> Void

    var body: some View {
        // Simple two-column-ish flow: chips wrap by rendering in an adaptive grid.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 96 * fontScale), spacing: 4, alignment: .leading)],
            alignment: .leading,
            spacing: 4
        ) {
            ForEach(rows) { row in
                Button {
                    onFocusPanel(row.panelId)
                } label: {
                    HStack(spacing: 3) {
                        SidebarAgentBrandIcon(row: row, fontScale: fontScale)
                        Text(row.paneLabel ?? SidebarAgentRowStateStyle.agentDisplayName(statusKey: row.statusKey))
                            .cmuxFont(size: 9.5 * fontScale, weight: .medium)
                            .foregroundColor(.primary.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 2.5)
                    .padding(.horizontal, 6)
                    .background(
                        Capsule()
                            .strokeBorder(
                                SidebarAgentRowStateStyle.stateColor(for: row) ?? Color.secondary.opacity(0.35),
                                lineWidth: 1
                            )
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .safeHelp([row.paneLabel, row.value].compactMap { $0 }.joined(separator: " · "))
            }
        }
    }
}

enum SidebarAgentRowLayout: Equatable {
    case nameFirst
    case tree
    case inCard(isActive: Bool, activeForeground: Color)
}

/// Shared state-styling helpers used by every variant.
enum SidebarAgentRowStateStyle {
    /// Brand marks for the structured agent status keys that have assets in
    /// `Assets.xcassets/AgentIcons`; keys without a mark fall back to the
    /// reported or lifecycle-derived SF symbol.
    static let brandAssetsByStatusKey: [String: String] = [
        "antigravity": "AgentIcons/Antigravity",
        "claude_code": "AgentIcons/Claude",
        "codex": "AgentIcons/Codex",
        "grok": "AgentIcons/Grok",
        "hermes-agent": "AgentIcons/HermesAgent",
        "opencode": "AgentIcons/OpenCode",
        "pi": "AgentIcons/Pi",
        "rovodev": "AgentIcons/RovoDev",
    ]

    static func agentDisplayName(statusKey: String) -> String {
        statusKey
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func effectiveColorHex(for row: SidebarAgentStatusRow) -> String? {
        if let color = row.color {
            return color
        }
        switch row.lifecycle {
        case .running:
            return "#4C8DFF"
        case .needsInput:
            return "#FF9F0A"
        case .idle, .unknown, nil:
            return nil
        }
    }

    static func stateColor(for row: SidebarAgentStatusRow) -> Color? {
        guard let raw = effectiveColorHex(for: row) else { return nil }
        return Color(hex: raw)
    }

    /// Short right-aligned state word for dense layouts.
    static func stateWord(for row: SidebarAgentStatusRow) -> String? {
        switch row.lifecycle {
        case .running:
            return String(localized: "sidebar.agentStatus.word.working", defaultValue: "working")
        case .needsInput:
            return String(localized: "sidebar.agentStatus.word.waiting", defaultValue: "waiting")
        case .idle:
            return String(localized: "sidebar.agentStatus.word.idle", defaultValue: "idle")
        case .unknown, nil:
            return nil
        }
    }

    static func lifecycleText(for row: SidebarAgentStatusRow) -> String? {
        switch row.lifecycle {
        case .running:
            return String(localized: "sidebar.agentStatus.running", defaultValue: "Running")
        case .needsInput:
            return String(localized: "sidebar.agentStatus.needsInput", defaultValue: "Needs input")
        case .idle:
            return String(localized: "sidebar.agentStatus.idle", defaultValue: "Idle")
        case .unknown, nil:
            return nil
        }
    }

    /// The row's status line: the reported value, else the lifecycle text.
    static func statusText(for row: SidebarAgentStatusRow) -> String? {
        if let value = row.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return lifecycleText(for: row)
    }
}

/// The agent's brand mark, or the reported/lifecycle SF symbol fallback.
struct SidebarAgentBrandIcon: View {
    let row: SidebarAgentStatusRow
    let fontScale: CGFloat

    var body: some View {
        if let asset = SidebarAgentRowStateStyle.brandAssetsByStatusKey[row.statusKey] {
            Image(asset)
                .resizable()
                .scaledToFit()
                .frame(width: 11 * fontScale, height: 11 * fontScale)
        } else if let symbol = fallbackSymbol {
            CmuxSystemSymbolImage(magnified: symbol, pointSize: 8 * fontScale, weight: .medium)
                .foregroundColor((SidebarAgentRowStateStyle.stateColor(for: row) ?? .secondary).opacity(0.95))
        }
    }

    private var fallbackSymbol: String? {
        if let icon = row.icon?.trimmingCharacters(in: .whitespacesAndNewlines), !icon.isEmpty {
            if icon.hasPrefix("sf:") { return String(icon.dropFirst(3)) }
            if icon.hasPrefix("emoji:") || icon.hasPrefix("text:") { return nil }
            return icon
        }
        switch row.lifecycle {
        case .running: return "bolt.fill"
        case .needsInput: return "exclamationmark.bubble.fill"
        case .idle: return "checkmark.circle"
        case .unknown, nil: return "person.crop.square"
        }
    }
}

/// One agent row. Primary text is the session/tab name (rename wins, then the
/// live surface title); the status rides second. Each row is its own
/// hover-highlighted button so clicks never fight workspace selection.
struct SidebarAgentStatusEntryRowView: View {
    let row: SidebarAgentStatusRow
    let fontScale: CGFloat
    let layout: SidebarAgentRowLayout
    let onFocusPanel: (UUID) -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            onFocusPanel(row.panelId)
            if let url = row.url {
                NSWorkspace.shared.open(url)
            }
        } label: {
            content
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(isHovering && !isInCard ? 0.07 : 0))
        )
        .onHover { isHovering = $0 }
        .safeHelp(helpText)
    }

    private var isInCard: Bool {
        if case .inCard = layout { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 4) {
            if case .tree = layout {
                Text(verbatim: "└")
                    .cmuxFont(size: 9 * fontScale)
                    .foregroundColor(.secondary.opacity(0.5))
            }
            SidebarAgentBrandIcon(row: row, fontScale: fontScale)
            if let stateColor = SidebarAgentRowStateStyle.stateColor(for: row) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 5 * fontScale, height: 5 * fontScale)
            }
            Text(primaryText)
                .cmuxFont(size: 10 * fontScale, weight: .medium)
                .foregroundColor(primaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
            if let status = statusLineText {
                statusTextView(status)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, isInCard ? 1 : 3)
        .padding(.horizontal, isInCard ? 0 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Session/tab name first; agent-type name when the pane has no title yet.
    private var primaryText: String {
        row.paneLabel ?? SidebarAgentRowStateStyle.agentDisplayName(statusKey: row.statusKey)
    }

    private var statusLineText: String? {
        SidebarAgentRowStateStyle.statusText(for: row)
    }

    @ViewBuilder
    private func statusTextView(_ status: String) -> some View {
        if row.format == .markdown,
           let attributed = try? AttributedString(
                markdown: status,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
           ) {
            Text(attributed)
                .cmuxFont(size: 9.5 * fontScale)
                .foregroundColor(secondaryColor)
        } else {
            Text(status)
                .cmuxFont(size: 9.5 * fontScale)
                .foregroundColor(secondaryColor)
        }
    }

    private var primaryColor: Color {
        if case let .inCard(isActive, activeForeground) = layout, isActive {
            return activeForeground
        }
        return .primary.opacity(0.85)
    }

    private var secondaryColor: Color {
        if case let .inCard(isActive, activeForeground) = layout, isActive {
            return activeForeground.opacity(0.65)
        }
        return .secondary.opacity(0.9)
    }

    private var helpText: String {
        [primaryText, statusLineText].compactMap { $0 }.joined(separator: " · ")
    }
}


/// The picked design (round-2 mock "G"): in-card accordion under the
/// workspace title, one row per agent with a right-aligned state word, and a
/// periwinkle accent bar + tint marking the ACTIVE agent (the workspace's
/// focused pane). Selection styling of the card itself is handled by
/// `TabItemView` (graphite instead of the blue selection) while this variant
/// is active.
struct SidebarAgentStatusGraphiteRows: View {
    static let accent = Color(red: 124 / 255, green: 140 / 255, blue: 248 / 255)

    let rows: [SidebarAgentStatusRow]
    let activePanelId: UUID?
    let isActive: Bool
    let activeForegroundColor: Color
    let fontScale: CGFloat
    let onFocus: () -> Void
    let onFocusPanel: (UUID) -> Void

    @State private var isCollapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header
            if !isCollapsed {
                ForEach(rows) { row in
                    SidebarAgentGraphiteRow(
                        row: row,
                        // Only the selected workspace hosts the globally
                        // focused pane; unselected workspaces remember a
                        // focus but the "camera" is not on them.
                        isActiveAgent: isActive && row.panelId == activePanelId,
                        isActive: isActive,
                        activeForegroundColor: activeForegroundColor,
                        fontScale: fontScale,
                        onFocusPanel: onFocusPanel
                    )
                }
            }
        }
        .padding(.top, 3)
    }

    private var header: some View {
        let summary = SidebarAgentStatusRowsSummary(rows: rows)
        return Button {
            onFocus()
            withAnimation(.easeInOut(duration: 0.15)) {
                isCollapsed.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                CmuxSystemSymbolImage(
                    magnified: isCollapsed ? "chevron.right" : "chevron.down",
                    pointSize: 6.5 * fontScale,
                    weight: .semibold
                )
                .foregroundColor(secondaryColor.opacity(0.8))
                if isCollapsed, let accent = summary.accentColorHex, let color = Color(hex: accent) {
                    Circle()
                        .fill(color)
                        .frame(width: 5 * fontScale, height: 5 * fontScale)
                }
                Text(summary.text)
                    .cmuxFont(size: 9.5 * fontScale, weight: .semibold)
                    .foregroundColor(secondaryColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .safeHelp(summary.text)
    }

    private var secondaryColor: Color {
        isActive ? activeForegroundColor.opacity(0.7) : .secondary
    }
}

private struct SidebarAgentGraphiteRow: View {
    let row: SidebarAgentStatusRow
    let isActiveAgent: Bool
    let isActive: Bool
    let activeForegroundColor: Color
    let fontScale: CGFloat
    let onFocusPanel: (UUID) -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            onFocusPanel(row.panelId)
        } label: {
            HStack(spacing: 6) {
                SidebarAgentBrandIcon(row: row, fontScale: fontScale)
                Text(row.paneLabel ?? SidebarAgentRowStateStyle.agentDisplayName(statusKey: row.statusKey))
                    .cmuxFont(size: 10.5 * fontScale, weight: .medium)
                    .foregroundColor(nameColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let stateColor = SidebarAgentRowStateStyle.stateColor(for: row) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 5 * fontScale, height: 5 * fontScale)
                }
                if let word = SidebarAgentRowStateStyle.stateWord(for: row) {
                    Text(word)
                        .cmuxFont(size: 9.5 * fontScale)
                        .foregroundColor(stateWordColor)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .safeHelp(tooltip)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isActiveAgent {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(SidebarAgentStatusGraphiteRows.accent.opacity(0.16))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(SidebarAgentStatusGraphiteRows.accent)
                        .frame(width: 2.5)
                        .padding(.vertical, 2)
                }
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.07 : 0))
        }
    }

    private var nameColor: Color {
        // isActiveAgent implies isActive (gated at the call site).
        if isActiveAgent {
            return activeForegroundColor
        }
        return isActive ? activeForegroundColor.opacity(0.92) : .primary.opacity(0.85)
    }

    private var stateWordColor: Color {
        if row.lifecycle == .needsInput {
            return Color(hex: "#FF9F0A") ?? .orange
        }
        return isActive ? activeForegroundColor.opacity(0.6) : .secondary.opacity(0.8)
    }

    private var tooltip: String {
        [
            row.paneLabel ?? SidebarAgentRowStateStyle.agentDisplayName(statusKey: row.statusKey),
            SidebarAgentRowStateStyle.statusText(for: row),
        ].compactMap { $0 }.joined(separator: " · ")
    }
}
