#if DEBUG
import SwiftUI

/// Routes gallery pages into the six static Atelier design-system screens.
struct AtelierGallery: View {
    let page: DesignGalleryPage

    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    var body: some View {
        let theme = AtelierTheme(scheme: colorScheme)

        Group {
            switch page {
            case .hub:
                AtelierHubScreen()
            case .session:
                AtelierSessionScreen()
            case .chat:
                AtelierChatScreen()
            case .activity:
                AtelierActivityScreen()
            case .settings:
                AtelierSettingsScreen()
            case .specimen:
                AtelierSpecimenScreen()
            }
        }
        .id(page)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .tint(theme.accent)
    }
}
#endif
