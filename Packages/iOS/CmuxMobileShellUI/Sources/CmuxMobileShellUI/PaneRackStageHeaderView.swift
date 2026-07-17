import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI
import UIKit

/// Forty-point staged-pane header that unfolds tabs and creates terminals.
struct PaneRackStageHeaderView: View {
    let pane: PaneRackPaneSnapshot
    let allPanes: [PaneRackPaneSnapshot]
    let chromeForeground: Color
    let background: Color
    let isUnfolded: Bool
    let toggleUnfold: () -> Void
    let createTab: () -> Void

    private var selectedTab: PaneRackTabSnapshot? { pane.selectedTab }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    PaneMiniGlyph(
                        panes: allPanes,
                        highlightedPaneID: pane.id,
                        strokeColor: chromeForeground.opacity(0.35),
                        fillColor: Color.accentColor.opacity(0.9)
                    )
                    Text(selectedTab?.title ?? "")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(chromeForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if pane.tabs.count > 1 {
                        Text(positionLabel)
                            .font(.caption2)
                            .foregroundStyle(chromeForeground.opacity(0.45))
                    }
                    PaneRackStatusDot(
                        color: selectedTab?.agentState.rackDotColor(chromeForeground: chromeForeground)
                            ?? chromeForeground.opacity(0.3),
                        size: 6
                    )
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(chromeForeground.opacity(0.6))
                        .rotationEffect(.degrees(isUnfolded ? 180 : 0))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                        .frame(width: 44, height: 40)
                }
                .padding(.leading, 12)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("PaneRackHeader")
            .accessibilityValue(selectedTab?.title ?? "")

            Button(action: createTab) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(chromeForeground.opacity(0.7))
                    .frame(width: 44, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("mobile.terminal.new", defaultValue: "New Terminal"))
            .accessibilityIdentifier("PaneRackNewTerminalButton")
            .padding(.trailing, 8)
        }
        .frame(height: 40)
        .background(background.overlay(Color.white.opacity(0.03)))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PlatformPalette.separator.opacity(0.25))
                .frame(height: 0.5)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isUnfolded)
    }

    private var positionLabel: String {
        let index = pane.tabs.firstIndex(where: { $0.id == selectedTab?.id }) ?? 0
        return "\(index + 1)/\(pane.tabs.count)"
    }

    private func toggle() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            toggleUnfold()
        }
    }
}
