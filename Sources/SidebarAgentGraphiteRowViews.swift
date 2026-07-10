import AppKit
import CmuxFoundation
import CmuxSidebar
import SwiftUI

/// Graphite (in-card) presentation of the per-agent rows, split from
/// `SidebarAgentStatusRowViews.swift` to satisfy the new-file length budget.
/// Rows receive immutable value snapshots and closure action bundles only,
/// per the sidebar list snapshot-boundary rule.
struct SidebarAgentStatusGraphiteRows: View {
    let rows: [SidebarAgentStatusRow]
    let activePanelId: UUID?
    let isActive: Bool
    let activeForegroundColor: Color
    let activeAgentRowColor: Color
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
                        activeAgentRowColor: activeAgentRowColor,
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
    let activeAgentRowColor: Color
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
                trailingState
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

    /// Running shows a spinner (no state word); waiting keeps the orange
    /// dot + word; idle shows nothing. Lifecycle-less rows (BYO agents that
    /// only reported a status) keep their reported color as a small dot.
    @ViewBuilder
    private var trailingState: some View {
        switch row.lifecycle {
        case .running:
            SidebarAgentRowSpinner(fontScale: fontScale)
        case .needsInput:
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
        case .idle, .unknown:
            EmptyView()
        case nil:
            if let raw = row.color, let reported = Color(hex: raw) {
                Circle()
                    .fill(reported)
                    .frame(width: 5 * fontScale, height: 5 * fontScale)
            }
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isActiveAgent {
            // "Even darker of the same color": the active agent sits in a
            // deeper shade of the card's own selection tint.
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(activeAgentRowColor)
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


/// Small native activity spinner sized for a sidebar agent row.
struct SidebarAgentRowSpinner: View {
    let fontScale: CGFloat

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .scaleEffect(0.55 * fontScale)
            .frame(width: 10 * fontScale, height: 10 * fontScale)
    }
}
