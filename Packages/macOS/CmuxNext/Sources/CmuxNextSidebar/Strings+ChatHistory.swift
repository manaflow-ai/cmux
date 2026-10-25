import Foundation

extension Strings {
    /// The session tree's history of chats no open workspace shows (`sidebar.sessionTree`).
    static var chatHistoryEarlier: String {
        String(localized: "sidebar.chatHistory.earlier", defaultValue: "Earlier", bundle: .module)
    }

    /// A history row's right-click menu: keep the chat at the top.
    static var chatHistoryPin: String {
        String(localized: "sidebar.chatHistory.pin", defaultValue: "Pin", bundle: .module)
    }

    static var chatHistoryUnpin: String {
        String(localized: "sidebar.chatHistory.unpin", defaultValue: "Unpin", bundle: .module)
    }

    /// The row under Earlier's page that lists the next one.
    static var chatHistoryShowMore: String {
        String(localized: "sidebar.chatHistory.showMore", defaultValue: "Show More", bundle: .module)
    }
}
