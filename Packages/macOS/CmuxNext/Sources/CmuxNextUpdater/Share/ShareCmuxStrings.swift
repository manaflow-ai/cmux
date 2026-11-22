import Foundation

/// The "cmux Updated!" card's and the Share cmux modal's strings
/// (Resources/Localizable.xcstrings; cx-7py7).
nonisolated enum ShareCmuxStrings {
    static var cardTitle: String { UpdaterStrings.text("updater.updated.title", "cmux Updated!") }
    static var cardWhatsNew: String { UpdaterStrings.text("updater.updated.whatsNew", "See What's New") }
    static var cardShare: String { UpdaterStrings.text("updater.updated.share", "Share cmux") }
    static var cardDismiss: String { UpdaterStrings.text("updater.updated.dismiss", "Hide Until the Next Update") }

    static var title: String { UpdaterStrings.text("share.title", "Share cmux with a Friend") }
    static var body: String { UpdaterStrings.text("share.body", "Send this message with the download link to a friend.") }
    static var message: String {
        UpdaterStrings.text("share.message", "Here's a link to download cmux, the terminal I was telling you about:")
    }
    static var messageLabel: String { UpdaterStrings.text("share.messageLabel", "Message") }
    static var copyLink: String { UpdaterStrings.text("share.copyLink", "Copy Link") }
    static var copied: String { UpdaterStrings.text("share.copied", "Copied") }
    static var close: String { UpdaterStrings.text("share.close", "Close") }
}

extension UpdaterService {
    /// The "cmux Updated!" card's text (the App fills `SidebarUpdatedCard`).
    public static var updatedCardTitle: String { ShareCmuxStrings.cardTitle }
    public static var updatedCardWhatsNewTitle: String { ShareCmuxStrings.cardWhatsNew }
    public static var updatedCardShareTitle: String { ShareCmuxStrings.cardShare }
    /// The x's tooltip and VoiceOver label.
    public static var updatedCardDismissLabel: String { ShareCmuxStrings.cardDismiss }
}
