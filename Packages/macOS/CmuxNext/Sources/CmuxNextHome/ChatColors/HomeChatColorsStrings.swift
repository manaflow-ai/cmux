import Foundation

/// The Chat Colors… panel's text (`Resources/Localizable.xcstrings`, `home.chatColors.*`).
enum HomeChatColorsStrings {
    static var title: String { String(localized: "home.chatColors.title", defaultValue: "Chat Colors", bundle: .l10n) }
    static var mine: String { String(localized: "home.chatColors.mine", defaultValue: "My Messages", bundle: .l10n) }
    static var theirs: String { String(localized: "home.chatColors.theirs", defaultValue: "Their Messages", bundle: .l10n) }
    static var bubble: String { String(localized: "home.chatColors.bubble", defaultValue: "Bubble", bundle: .l10n) }
    static var text: String { String(localized: "home.chatColors.text", defaultValue: "Text", bundle: .l10n) }
    static var automatic: String { String(localized: "home.chatColors.automatic", defaultValue: "Automatic (readable on the bubble)", bundle: .l10n) }
    static var styleDefault: String { String(localized: "home.chatColors.default", defaultValue: "Default", bundle: .l10n) }
    static var custom: String { String(localized: "home.chatColors.custom", defaultValue: "Custom Color", bundle: .l10n) }
    static var reset: String { String(localized: "home.chatColors.reset", defaultValue: "Reset to Default", bundle: .l10n) }
    static var done: String { String(localized: "home.chatColors.done", defaultValue: "Done", bundle: .l10n) }
    static var previewLabel: String { String(localized: "home.chatColors.preview", defaultValue: "Preview", bundle: .l10n) }
    static var sampleSent: String { String(localized: "home.chatColors.sample.sent", defaultValue: "Looks good to me!", bundle: .l10n) }
    static var sampleReceived: String { String(localized: "home.chatColors.sample.received", defaultValue: "How do these colors look?", bundle: .l10n) }
}
