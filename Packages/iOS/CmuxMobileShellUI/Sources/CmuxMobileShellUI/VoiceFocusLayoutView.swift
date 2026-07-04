#if os(iOS)
import CmuxMobileRPC
import CmuxMobileSupport
import SwiftUI

/// Miniature selected-workspace split layout for Voice Mode targeting.
struct VoiceFocusLayoutView: View {
    let layout: MobileFocusSnapshotLayout

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    )

                ForEach(Array(layout.panes.enumerated()), id: \.offset) { index, pane in
                    paneView(pane: pane, index: index, size: proxy.size)
                }
            }
        }
        .aspectRatio(1.6, contentMode: .fit)
        .accessibilityIdentifier("MobileVoiceModeLayoutMiniature")
    }

    private func paneView(
        pane: MobileFocusSnapshotLayoutPane,
        index: Int,
        size: CGSize
    ) -> some View {
        let rect = pane.rect.clampedFrame(in: size)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(pane.focused ? Color.accentColor.opacity(0.22) : Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(pane.focused ? Color.accentColor : Color.secondary.opacity(0.22), lineWidth: pane.focused ? 2 : 1)
                )

            HStack(spacing: 4) {
                Image(systemName: pane.isTerminal ? "terminal" : "globe")
                    .font(.caption2.weight(.semibold))
                Text(pane.title ?? L10n.string("mobile.voiceMode.layoutPaneFallback", defaultValue: "Pane"))
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(pane.focused ? Color.accentColor : Color.secondary)
            .padding(6)
            .opacity(pane.isTerminal ? 1 : 0.62)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .accessibilityIdentifier("MobileVoiceModeLayoutPane\(index)")
    }
}

private extension MobileFocusSnapshotLayoutRect {
    func clampedFrame(in size: CGSize) -> CGRect {
        let clampedX = min(1, max(0, x))
        let clampedY = min(1, max(0, y))
        let clampedWidth = min(1 - clampedX, max(0.02, width))
        let clampedHeight = min(1 - clampedY, max(0.08, height))
        return CGRect(
            x: clampedX * size.width,
            y: clampedY * size.height,
            width: max(24, clampedWidth * size.width),
            height: max(24, clampedHeight * size.height)
        )
    }
}
#endif
