#if DEBUG
import SwiftUI

/// Renders the full shared agent conversation with Atelier's generous rhythm.
struct AtelierChatScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = AtelierTheme(scheme: colorScheme)
        let workspace = DesignGalleryFixtures.workspaces[0]

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Conversation")
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                        .foregroundStyle(theme.textPrimary)
                    HStack(spacing: 8) {
                        AtelierStatusMark(state: workspace.state)
                        Text("· \(workspace.name)")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .padding(.bottom, 4)

                ForEach(DesignGalleryFixtures.chatEntries) { entry in
                    AtelierChatEntryView(entry: entry)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.bottom)
        .background(theme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AtelierComposer(placeholder: "Reply to Claude…")
                .background(theme.background.opacity(0.92))
        }
    }
}
#endif
