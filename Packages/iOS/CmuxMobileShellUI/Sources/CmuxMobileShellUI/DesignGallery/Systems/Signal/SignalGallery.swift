#if DEBUG
import SwiftUI

/// Routes gallery pages into the six static Signal design-system screens.
struct SignalGallery: View {
    let page: DesignGalleryPage

    var body: some View {
        switch page {
        case .hub:
            SignalHubScreen()
        case .session:
            SignalSessionScreen()
        case .chat:
            SignalChatScreen()
        case .activity:
            SignalActivityScreen()
        case .settings:
            SignalSettingsScreen()
        case .specimen:
            SignalSpecimenScreen()
        }
    }
}
#endif
