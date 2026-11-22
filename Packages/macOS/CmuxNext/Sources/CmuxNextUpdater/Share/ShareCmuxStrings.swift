import Foundation

/// The Share cmux modal's strings
/// (Resources/Localizable.xcstrings; cx-7py7).
nonisolated enum ShareCmuxStrings {
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
