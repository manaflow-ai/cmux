#if DEBUG
import SwiftUI

/// Displays all fixture workspaces as Signal's grouped, fixed-column fleet board.
struct SignalHubScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = SignalTheme(scheme: colorScheme)
        let statuses = [
            GalleryAgentState.needsYou,
            GalleryAgentState.failed,
            GalleryAgentState.running,
            GalleryAgentState.done,
            GalleryAgentState.idle,
        ]

        ScrollView {
            VStack(spacing: 24) {
                ForEach(Array(statuses.enumerated()), id: \.offset) { _, state in
                    let status = SignalStatusStyle(state: state, theme: theme)
                    let workspaces = DesignGalleryFixtures.workspaces.filter { status.matches($0.state) }

                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            SignalStatusSquare(color: status.color)
                            SignalSectionLabel(text: status.label, color: theme.ink)
                            Text(status.symbol)
                                .font(.system(.footnote, design: .monospaced, weight: .bold))
                                .foregroundStyle(theme.ink)
                            Spacer()
                            Text("\(workspaces.count)")
                                .font(.system(.footnote, design: .monospaced, weight: .regular))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .frame(minHeight: 24)

                        ForEach(workspaces) { workspace in
                            SignalWorkspaceRow(workspace: workspace, theme: theme)
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(theme.hairline)
                                        .frame(height: 1)
                                }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 112)
            .padding(.bottom, 16)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                Text("Hub")
                    .font(.system(.title, design: .default, weight: .heavy))
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 38)
                    .background(theme.bg0)

                SignalSummaryStrip(theme: theme)
            }
            .padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SignalTriageBar(theme: theme)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg0.ignoresSafeArea())
    }
}
#endif
