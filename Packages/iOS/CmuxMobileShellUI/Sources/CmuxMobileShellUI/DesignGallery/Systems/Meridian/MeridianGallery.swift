#if DEBUG
import SwiftUI

/// Routes the gallery's shared page selection into the Meridian design system.
struct MeridianGallery: View {
    let page: DesignGalleryPage

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        pageContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 8) {
                MeridianFloatingTabBar(selectedPage: page)
                    .padding(.horizontal, 48)
            }
    }

    private var theme: MeridianTheme {
        MeridianTheme(scheme: colorScheme)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .hub:
            MeridianHubScreen()
        case .session:
            MeridianSessionScreen()
        case .chat:
            MeridianChatScreen()
        case .activity:
            MeridianActivityScreen()
        case .settings:
            MeridianSettingsScreen()
        case .specimen:
            MeridianSpecimenScreen()
        }
    }
}
#endif
