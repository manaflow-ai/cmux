#if DEBUG
import CmuxMobileSupport
import SwiftUI

/// Presents the pinned fleet legend at Signal's sole Liquid Glass site.
struct SignalSummaryStrip: View {
    let theme: SignalTheme

    private var statuses: [GalleryAgentState] {
        [.needsYou, .failed, .running, .done, .idle]
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(statuses.enumerated()), id: \.offset) { _, state in
                let style = SignalStatusStyle(state: state, theme: theme)
                let count = DesignGalleryFixtures.workspaces.filter { style.matches($0.state) }.count
                SignalLegendItem(style: style, count: count, theme: theme)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .mobileGlassField(cornerRadius: 4)
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(theme.hairline, lineWidth: 1)
        }
        .allowsHitTesting(false)
        .padding(.horizontal, 16)
    }
}
#endif
