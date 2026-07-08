import AppKit
import CmuxFoundation
import CmuxSidebar
import SwiftUI

/// Aggregate over the agent rows of one workspace, shown in the accordion
/// header (and standing in for the rows while collapsed).
struct SidebarAgentStatusRowsSummary: Equatable {
    let agentCount: Int
    let needsInputCount: Int
    let runningCount: Int

    init(rows: [SidebarAgentStatusRow]) {
        agentCount = rows.count
        needsInputCount = rows.filter { $0.lifecycle == .needsInput }.count
        runningCount = rows.filter { $0.lifecycle == .running }.count
    }

    var text: String {
        var parts: [String] = []
        if agentCount == 1 {
            parts.append(String(localized: "sidebar.agentStatus.summary.oneAgent", defaultValue: "1 agent"))
        } else {
            parts.append(String(
                format: String(localized: "sidebar.agentStatus.summary.agentCount", defaultValue: "%lld agents"),
                agentCount
            ))
        }
        if needsInputCount == 1 {
            parts.append(String(localized: "sidebar.agentStatus.summary.oneNeedsInput", defaultValue: "1 needs input"))
        } else if needsInputCount > 1 {
            parts.append(String(
                format: String(localized: "sidebar.agentStatus.summary.needsInputCount", defaultValue: "%lld need input"),
                needsInputCount
            ))
        }
        return parts.joined(separator: " · ")
    }

    /// Worst-state accent: needs-input beats running beats idle.
    var accentColorHex: String? {
        if needsInputCount > 0 { return "#FF9F0A" }
        if runningCount > 0 { return "#4C8DFF" }
        return nil
    }
}

/// Sidebar per-agent-pane status rows: one row per live agent pane plus its
/// private entry row. With more than one agent the block becomes an accordion:
/// a summary header ("2 agents · 1 needs input") that folds the rows. Rows
/// receive immutable value snapshots and closure action bundles only, per the
/// sidebar list snapshot-boundary rule.
struct SidebarAgentStatusRows: View {
    let rows: [SidebarAgentStatusRow]
    let isActive: Bool
    let activeForegroundColor: Color
    let fontScale: CGFloat
    let onFocus: () -> Void
    let onFocusPanel: (UUID) -> Void

    @State private var isCollapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if rows.count > 1 {
                accordionHeader
                if !isCollapsed {
                    rowList
                }
            } else {
                rowList
            }
        }
    }

    private var rowList: some View {
        ForEach(rows) { row in
            SidebarAgentStatusEntryRow(
                row: row,
                isActive: isActive,
                activeForegroundColor: activeForegroundColor,
                fontScale: fontScale,
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
                .foregroundColor(headerSecondaryColor)
                if isCollapsed, let accent = summary.accentColorHex, let color = Color(hex: accent), !isActive {
                    Circle()
                        .fill(color)
                        .frame(width: 5 * fontScale, height: 5 * fontScale)
                }
                Text(summary.text)
                    .foregroundColor(headerForegroundColor)
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

    private var headerForegroundColor: Color {
        isActive ? activeForegroundColor : .secondary
    }

    private var headerSecondaryColor: Color {
        isActive ? activeForegroundColor.opacity(0.65) : .secondary.opacity(0.8)
    }
}

private struct SidebarAgentStatusEntryRow: View {
    let row: SidebarAgentStatusRow
    let isActive: Bool
    let activeForegroundColor: Color
    let fontScale: CGFloat
    let onFocusPanel: (UUID) -> Void

    var body: some View {
        Group {
            if let url = row.url {
                Button {
                    onFocusPanel(row.panelId)
                    NSWorkspace.shared.open(url)
                } label: {
                    rowContent(underlined: true)
                }
                .buttonStyle(.plain)
                .safeHelp(url.absoluteString)
            } else {
                rowContent(underlined: false)
                    .contentShape(Rectangle())
                    .onTapGesture { onFocusPanel(row.panelId) }
                    .safeHelp(helpText)
            }
        }
    }

    @ViewBuilder
    private func rowContent(underlined: Bool) -> some View {
        HStack(spacing: 4) {
            if let icon = iconView {
                icon
                    .foregroundColor(foregroundColor.opacity(0.95))
            }
            statusText(underlined: underlined)
                .lineLimit(1)
                .truncationMode(.tail)
            if let paneLabel = row.paneLabel {
                Text(paneLabel)
                    .foregroundColor(isActive ? activeForegroundColor.opacity(0.6) : .secondary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .cmuxFont(size: 10 * fontScale)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Mirrors `SidebarMetadataEntryRow.metadataText`: a markdown-formatted
    /// reported value keeps its inline markdown rendering after moving from
    /// the generic metadata renderer into the per-agent row. Lifecycle/name
    /// fallback text is always plain.
    @ViewBuilder
    private func statusText(underlined: Bool) -> some View {
        if row.format == .markdown,
           reportedValueText != nil,
           let attributed = try? AttributedString(
                markdown: displayText,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
           ) {
            Text(attributed)
                .underline(underlined)
                .foregroundColor(foregroundColor)
        } else {
            Text(displayText)
                .underline(underlined)
                .foregroundColor(foregroundColor)
        }
    }

    private var reportedValueText: String? {
        guard let value = row.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private var displayText: String {
        if let value = reportedValueText {
            return value
        }
        let name = Self.agentDisplayName(statusKey: row.statusKey)
        if let lifecycleText {
            return "\(name): \(lifecycleText)"
        }
        return name
    }

    private var helpText: String {
        guard let paneLabel = row.paneLabel else { return displayText }
        return "\(displayText) (\(paneLabel))"
    }

    private var lifecycleText: String? {
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

    static func agentDisplayName(statusKey: String) -> String {
        statusKey
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private var effectiveIcon: String? {
        if let icon = row.icon?.trimmingCharacters(in: .whitespacesAndNewlines), !icon.isEmpty {
            return icon
        }
        switch row.lifecycle {
        case .running:
            return "bolt.fill"
        case .needsInput:
            return "exclamationmark.bubble.fill"
        case .idle:
            return "checkmark.circle"
        case .unknown, nil:
            return nil
        }
    }

    private var effectiveColorHex: String? {
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

    private var foregroundColor: Color {
        if isActive {
            return activeForegroundColor
        }
        if let raw = effectiveColorHex, let explicit = Color(hex: raw) {
            return explicit
        }
        return .secondary
    }

    private var iconView: AnyView? {
        guard let iconRaw = effectiveIcon else { return nil }
        if iconRaw.hasPrefix("emoji:") {
            let value = String(iconRaw.dropFirst("emoji:".count))
            guard !value.isEmpty else { return nil }
            return AnyView(Text(value).cmuxFont(size: 9 * fontScale))
        }
        if iconRaw.hasPrefix("text:") {
            let value = String(iconRaw.dropFirst("text:".count))
            guard !value.isEmpty else { return nil }
            return AnyView(Text(value).cmuxFont(size: 8 * fontScale, weight: .semibold))
        }
        let symbolName: String
        if iconRaw.hasPrefix("sf:") {
            symbolName = String(iconRaw.dropFirst("sf:".count))
        } else {
            symbolName = iconRaw
        }
        guard !symbolName.isEmpty else { return nil }
        return AnyView(CmuxSystemSymbolImage(magnified: symbolName, pointSize: 8 * fontScale, weight: .medium))
    }
}
