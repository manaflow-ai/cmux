import AppKit
import CmuxFoundation
import CmuxSidebar
import SwiftUI

/// Sidebar per-agent-pane status rows: one row per live agent pane plus its
/// private entry row. Rows receive immutable value snapshots and closure
/// action bundles only, per the sidebar list snapshot-boundary rule.
struct SidebarAgentStatusRows: View {
    let rows: [SidebarAgentStatusRow]
    let isActive: Bool
    let activeForegroundColor: Color
    let fontScale: CGFloat
    let onFocusPanel: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
            Text(displayText)
                .underline(underlined)
                .foregroundColor(foregroundColor)
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

    private var displayText: String {
        if let value = row.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
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
