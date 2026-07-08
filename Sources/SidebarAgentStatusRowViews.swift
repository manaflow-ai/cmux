import AppKit
import CmuxFoundation
import CmuxSidebar
import SwiftUI

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
            if let brandAssetName {
                Image(brandAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 11 * fontScale, height: 11 * fontScale)
                if let stateColor {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 5 * fontScale, height: 5 * fontScale)
                }
            } else if let icon = iconView {
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

    /// Brand marks for the structured agent status keys that have assets in
    /// `Assets.xcassets/AgentIcons`; keys without a mark keep the reported or
    /// lifecycle-derived SF symbol.
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

    private var brandAssetName: String? {
        Self.brandAssetsByStatusKey[row.statusKey]
    }

    /// Lifecycle/report state shown as a dot next to the brand mark, which
    /// replaces the state-colored SF symbol when a brand asset exists.
    private var stateColor: Color? {
        guard let raw = effectiveColorHex else { return nil }
        return Color(hex: raw)
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
