#if DEBUG
import SwiftUI

/// Shows fixture metadata, approval actions, and the complete terminal transcript.
struct SignalSessionScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    private var workspace: GalleryWorkspaceFixture {
        DesignGalleryFixtures.workspaces[0]
    }

    var body: some View {
        let theme = SignalTheme(scheme: colorScheme)
        let status = SignalStatusStyle(state: workspace.state, theme: theme)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Session")
                    .font(.system(.title, design: .default, weight: .heavy))
                    .foregroundStyle(theme.ink)

                VStack(alignment: .leading, spacing: 8) {
                    SignalSectionLabel(text: "Metadata", color: theme.secondaryText)

                    VStack(spacing: 0) {
                        SignalMetadataRow(label: "Agent", value: workspace.agentName, state: nil, theme: theme)
                        SignalMetadataRow(label: "State", value: "\(status.label) \(status.symbol)", state: workspace.state, theme: theme)
                        SignalMetadataRow(label: "Branch", value: workspace.branch, state: nil, theme: theme)
                        SignalMetadataRow(label: "Elapsed", value: workspace.elapsedText, state: nil, theme: theme)
                        SignalMetadataRow(label: "Port", value: "—", state: nil, theme: theme)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(theme.hairline, lineWidth: 1)
                    }

                    SignalActionButtons(theme: theme)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SignalSectionLabel(text: "Terminal", color: theme.secondaryText)
                        Spacer()
                        Text("14 LINES")
                            .font(.system(.footnote, design: .monospaced, weight: .regular))
                            .foregroundStyle(theme.secondaryText)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(DesignGalleryFixtures.terminalLines) { line in
                                SignalTerminalLineRow(line: line, theme: theme)
                            }
                        }
                        .padding(12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(theme.hairline, lineWidth: 1)
                    }
                }
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SignalTriageBar(theme: theme)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg0.ignoresSafeArea())
    }
}
#endif
