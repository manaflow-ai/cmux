import CmuxFoundation
import SwiftUI

/// A compact per-pane control bar shown above each mirrored tmux pane.
@MainActor
struct RemoteTmuxPaneHeader: View {
    /// The header's fixed height in points — the per-pane chrome constant the
    /// sizing geometry folds (the bottom divider is an overlay INSIDE this
    /// frame, so it adds no height).
    static let totalHeightPt: CGFloat = 24

    let isActive: Bool
    let appearance: PanelAppearance
    let onFocus: () -> Void
    let onSplitRight: () -> Void
    let onSplitDown: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 6, height: 6)
            Spacer(minLength: 0)
            button(
                system: "square.split.2x1",
                label: String(localized: "remoteTmux.pane.splitRight", defaultValue: "Split Right"),
                action: onSplitRight
            )
            button(
                system: "square.split.1x2",
                label: String(localized: "remoteTmux.pane.splitDown", defaultValue: "Split Down"),
                action: onSplitDown
            )
            button(
                system: "xmark",
                label: String(localized: "remoteTmux.pane.close", defaultValue: "Close Pane"),
                action: onClose
            )
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: appearance.backgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(appearance.dividerColor).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
    }

    private func button(system: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CmuxSystemSymbolImage(magnified: system, pointSize: 11, weight: .medium)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}
