import Foundation

/// The Chat Colors… panel's text (`Resources/Localizable.xcstrings`, `home.chatColors.*`).
enum HomeChatColorsStrings {
    static var title: String { String(localized: "home.chatColors.title", defaultValue: "Chat Colors", bundle: .localizedModule) }
    static var mine: String { String(localized: "home.chatColors.mine", defaultValue: "My Messages", bundle: .localizedModule) }
    static var theirs: String { String(localized: "home.chatColors.theirs", defaultValue: "Their Messages", bundle: .localizedModule) }
    static var bubble: String { String(localized: "home.chatColors.bubble", defaultValue: "Bubble", bundle: .localizedModule) }
    static var text: String { String(localized: "home.chatColors.text", defaultValue: "Text", bundle: .localizedModule) }
    static var automatic: String { String(localized: "home.chatColors.automatic", defaultValue: "Automatic (readable on the bubble)", bundle: .localizedModule) }
    static var styleDefault: String { String(localized: "home.chatColors.default", defaultValue: "Default", bundle: .localizedModule) }
    static var custom: String { String(localized: "home.chatColors.custom", defaultValue: "Custom Color", bundle: .localizedModule) }
    static var reset: String { String(localized: "home.chatColors.reset", defaultValue: "Reset to Default", bundle: .localizedModule) }
    static var done: String { String(localized: "home.chatColors.done", defaultValue: "Done", bundle: .localizedModule) }
    static var previewLabel: String { String(localized: "home.chatColors.preview", defaultValue: "Preview", bundle: .localizedModule) }
    static var sampleSent: String { String(localized: "home.chatColors.sample.sent", defaultValue: "Looks good to me!", bundle: .localizedModule) }
    static var sampleReceived: String { String(localized: "home.chatColors.sample.received", defaultValue: "How do these colors look?", bundle: .localizedModule) }
}
