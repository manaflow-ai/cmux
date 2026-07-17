import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// Snapshot-only row for one staged-pane terminal tab.
struct PaneRackTabRow: View {
    let tab: PaneRackTabSnapshot
    let tail: PaneTail?
    let isSelected: Bool
    let canClose: Bool
    let chromeForeground: Color
    let background: Color
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 10) {
                    PaneRackStatusDot(
                        color: tab.agentState.rackDotColor(chromeForeground: chromeForeground),
                        size: 8
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tab.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? Color.accentColor : chromeForeground)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(tail?.rows.last ?? "")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(chromeForeground.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 15)
                .padding(.trailing, canClose ? 0 : 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("PaneRackTabRow-\(tab.id.rawValue)")

            if canClose {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(chromeForeground.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tabCloseLabel)
                .accessibilityIdentifier("PaneRackTabClose-\(tab.id.rawValue)")
            }
        }
        .frame(height: 44)
        .background(background)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 3)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PlatformPalette.separator.opacity(0.25))
                .frame(height: 0.5)
        }
    }

    private var tabCloseLabel: String {
        String.localizedStringWithFormat(
            L10n.string("mobile.paneRack.closeTab.accessibilityLabel", defaultValue: "Close %@"),
            tab.title
        )
    }
}
