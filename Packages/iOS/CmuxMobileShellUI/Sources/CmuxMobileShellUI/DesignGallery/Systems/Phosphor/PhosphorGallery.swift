#if DEBUG
import SwiftUI

/// Routes gallery pages into the six Phosphor design-system specimens.
struct PhosphorGallery: View {
    let page: DesignGalleryPage

    var body: some View {
        Group {
            switch page {
            case .hub:
                PhosphorHubScreen()
            case .session:
                PhosphorSessionScreen()
            case .chat:
                PhosphorChatScreen()
            case .activity:
                PhosphorActivityScreen()
            case .settings:
                PhosphorSettingsScreen()
            case .specimen:
                PhosphorSpecimenScreen()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
