import CmuxMobileSupport
import SwiftUI

/// Thin persistent handle that reveals the hidden pane tab strip.
struct PaneTabStripHandle: View {
    let revealByTap: () -> Void
    let revealByUpwardDrag: () -> Void

    var body: some View {
        Button(action: revealByTap) {
            Capsule()
                .fill(.secondary)
                .frame(width: 52, height: 5)
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string("mobile.paneTabStrip.show", defaultValue: "Show Tabs"))
        .accessibilityIdentifier("MobilePaneTabStripHandle")
        .simultaneousGesture(
            DragGesture(minimumDistance: 4).onEnded { value in
                if value.translation.height < -8 {
                    revealByUpwardDrag()
                }
            }
        )
    }
}
