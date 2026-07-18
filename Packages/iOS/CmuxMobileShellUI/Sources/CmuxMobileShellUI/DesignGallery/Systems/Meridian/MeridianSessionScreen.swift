#if DEBUG
import CmuxMobileSupport
import SwiftUI

/// Renders the full terminal transcript edge-to-edge beneath floating glass session chrome.
struct MeridianSessionScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 7) {
                ForEach(DesignGalleryFixtures.terminalLines) { line in
                    MeridianTerminalLineView(line: line)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 78)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
        .background(theme.background.ignoresSafeArea())
        .overlay(alignment: .top) {
            statusCapsule
                .padding(.top, 10)
        }
        .safeAreaInset(edge: .bottom, spacing: 8) {
            HStack {
                Spacer()
                MeridianActionCluster(approvalPending: true)
            }
            .padding(.horizontal, theme.horizontalInset)
        }
        .tint(theme.accent)
    }

    private var theme: MeridianTheme {
        MeridianTheme(scheme: colorScheme)
    }

    private var statusCapsule: some View {
        let workspace = DesignGalleryFixtures.workspaces[0]
        return HStack(spacing: 9) {
            MeridianStatusSymbol(state: workspace.state, font: .headline)
            Text(workspace.name)
                .font(.headline)
            Text(workspace.branch)
                .font(.caption.monospaced())
                .foregroundStyle(theme.secondaryLabel)
                .lineLimit(1)
            Text(workspace.elapsedText)
                .font(.caption)
                .foregroundStyle(theme.secondaryLabel)
        }
        .foregroundStyle(theme.label)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .mobileGlassPill()
        .padding(.horizontal, 20)
    }
}
#endif
