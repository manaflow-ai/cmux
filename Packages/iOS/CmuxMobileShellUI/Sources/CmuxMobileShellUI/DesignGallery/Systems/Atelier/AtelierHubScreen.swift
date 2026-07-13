#if DEBUG
import SwiftUI

/// Shows every workspace fixture in Atelier's low-density, action-forward hub.
struct AtelierHubScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = AtelierTheme(scheme: colorScheme)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your agents")
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                        .foregroundStyle(theme.textPrimary)
                    Text("A quiet view of what needs you now.")
                        .font(.system(size: 16))
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(.bottom, 8)

                ForEach(DesignGalleryFixtures.workspaces) { workspace in
                    AtelierWorkspaceCard(workspace: workspace)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(theme.background)
    }
}
#endif
