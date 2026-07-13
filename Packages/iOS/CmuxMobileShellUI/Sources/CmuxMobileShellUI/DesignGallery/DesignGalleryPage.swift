#if DEBUG
import CmuxMobileSupport

/// A screen category shared by every candidate design system in the gallery.
enum DesignGalleryPage: String, CaseIterable, Identifiable {
    case hub
    case session
    case chat
    case activity
    case settings
    case specimen

    /// The stable identifier used by gallery navigation controls.
    var id: String { rawValue }

    /// The localized title displayed in gallery navigation and placeholders.
    var title: String {
        switch self {
        case .hub:
            L10n.string("mobile.designGallery.page.hub", defaultValue: "Hub")
        case .session:
            L10n.string("mobile.designGallery.page.session", defaultValue: "Session")
        case .chat:
            L10n.string("mobile.designGallery.page.chat", defaultValue: "Chat")
        case .activity:
            L10n.string("mobile.designGallery.page.activity", defaultValue: "Activity")
        case .settings:
            L10n.string("mobile.designGallery.page.settings", defaultValue: "Settings")
        case .specimen:
            L10n.string("mobile.designGallery.page.specimen", defaultValue: "Specimen")
        }
    }

    /// The SF Symbol used for the page in the bottom picker.
    var symbolName: String {
        switch self {
        case .hub: "square.grid.2x2"
        case .session: "terminal"
        case .chat: "bubble.left.and.bubble.right"
        case .activity: "bell"
        case .settings: "gearshape"
        case .specimen: "paintpalette"
        }
    }
}
#endif
