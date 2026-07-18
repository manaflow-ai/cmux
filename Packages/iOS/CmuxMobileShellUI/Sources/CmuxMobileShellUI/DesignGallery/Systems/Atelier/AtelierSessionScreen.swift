#if DEBUG
import SwiftUI

/// Frames the complete terminal transcript as a dark artifact on warm paper.
struct AtelierSessionScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = AtelierTheme(scheme: colorScheme)
        let workspace = DesignGalleryFixtures.workspaces[1]

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Session")
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                        .foregroundStyle(theme.textPrimary)
                    Text("\(workspace.name) · \(workspace.branch)")
                        .font(.system(size: 16))
                        .foregroundStyle(theme.textSecondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        AtelierStatusMark(state: workspace.state)
                        Spacer()
                        Text("\(workspace.agentName) · \(workspace.elapsedText)")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textTertiary)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(DesignGalleryFixtures.terminalLines) { line in
                            AtelierTerminalLineView(line: line)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        theme.terminalBackground,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }
                .padding(16)
                .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(theme.hairline, lineWidth: 1)
                }
                .shadow(color: theme.cardShadow, radius: 12, x: 0, y: 2)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .background(theme.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AtelierComposer(placeholder: "Send a message…")
                .background(theme.background.opacity(0.92))
        }
    }
}
#endif
