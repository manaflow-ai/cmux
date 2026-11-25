import Foundation

// The block's own words (Earlier, Show More, Loading chats…) are the page's (webviews/src/pages/sidebar-chats,
// through webviews/scripts/pages/gen-strings.mjs from this package's catalog); the menu's stay here.
extension Strings {
    /// A history row's right-click menu: keep the chat at the top.
    static var chatHistoryPin: String {
        String(localized: "sidebar.chatHistory.pin", defaultValue: "Pin", bundle: .module)
    }

    static var chatHistoryUnpin: String {
        String(localized: "sidebar.chatHistory.unpin", defaultValue: "Unpin", bundle: .module)
    }
}
