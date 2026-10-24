import Foundation
import LinkPresentation

/// "Invite to cmux": the Chief header's trailing button shares a short note
/// and the public cmux link through the system share sheet, so people can pass
/// cmux on to friends. It is not the team invite (Settings), which adds
/// someone to a team; this one only points at cmux.
///
/// The link is the public site, cmux.com: the Mac app's Share cmux names
/// cmux.com/download, but that page answers 404 today; the site's home page
/// is live, carries the Mac download and the iOS page, and has its own
/// preview image. No referral or tracking parameters.
enum ChiefInvite {
    /// The public cmux site.
    static let url = URL(string: "https://cmux.com") ?? URL(fileURLWithPath: "/")

    /// The note above the link.
    static var message: String {
        String(localized: "I'm using cmux to run my coding agents from my phone. Try it:")
    }

    /// The share sheet's button and its spoken label.
    static var actionTitle: String { String(localized: "Invite to cmux") }

    /// The header glyph.
    static let symbol = "person.badge.plus"

    /// The share sheet's preview (and the link's title in apps that read it):
    /// the cmux name and the app's icon, with the public link.
    static func metadata(icon: NSItemProvider? = nil) -> LPLinkMetadata {
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        metadata.title = "cmux"
        metadata.iconProvider = icon
        return metadata
    }
}

#if os(iOS)
import UIKit

extension ChiefInvite {
    /// The share sheet: the note, then the link with its preview.
    @MainActor static func shareSheet() -> UIActivityViewController {
        UIActivityViewController(activityItems: [message, LinkItem()], applicationActivities: nil)
    }

    /// This app's icon, as the system shows it on the Home Screen.
    @MainActor static func appIcon() -> UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] else { return nil }
        if let name = primary["CFBundleIconName"] as? String, let image = UIImage(named: name) { return image }
        if let files = primary["CFBundleIconFiles"] as? [String], let name = files.last { return UIImage(named: name) }
        return nil
    }

    /// The link, with the preview the share sheet draws at its top.
    final class LinkItem: NSObject, UIActivityItemSource {
        private let metadata: LPLinkMetadata

        @MainActor override init() {
            metadata = ChiefInvite.metadata(icon: ChiefInvite.appIcon().map { NSItemProvider(object: $0) })
            super.init()
        }

        func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { ChiefInvite.url }

        func activityViewController(_ controller: UIActivityViewController,
                                    itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
            ChiefInvite.url
        }

        func activityViewController(_ controller: UIActivityViewController,
                                    subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
            ChiefInvite.actionTitle
        }

        func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
            metadata
        }
    }
}
#endif
