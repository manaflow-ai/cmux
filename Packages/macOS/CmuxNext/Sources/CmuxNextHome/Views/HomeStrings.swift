import Foundation

/// Every user-facing string of the Home module (Localizable.xcstrings).
enum HomeStrings {
    static var thisMacOnly: String { String(localized: "home.owner.thisMac", defaultValue: "This Mac only", bundle: .module) }
    static var messagePlaceholder: String { String(localized: "home.composer.placeholder", defaultValue: "Message", bundle: .module) }
    static var sending: String { String(localized: "home.receipt.sending", defaultValue: "Sending", bundle: .module) }
    static var notDelivered: String { String(localized: "home.receipt.failed", defaultValue: "Not delivered", bundle: .module) }
    static var tapToRetry: String { String(localized: "home.receipt.retry", defaultValue: "Click to retry", bundle: .module) }
    static var read: String { String(localized: "home.receipt.read", defaultValue: "Read", bundle: .module) }
    static var delivered: String { String(localized: "home.receipt.delivered", defaultValue: "Delivered", bundle: .module) }
    static var today: String { String(localized: "home.separator.today", defaultValue: "Today", bundle: .module) }
    static var yesterday: String { String(localized: "home.separator.yesterday", defaultValue: "Yesterday", bundle: .module) }
    static var newConversation: String {
        String(localized: "home.list.newConversation", defaultValue: "New Conversation", bundle: .module)
    }
    static var conversations: String { String(localized: "home.list.title", defaultValue: "Conversations", bundle: .module) }
    static var noConversation: String {
        String(localized: "home.transcript.empty", defaultValue: "No conversation selected", bundle: .module)
    }
    static var retracted: String { String(localized: "home.row.retracted", defaultValue: "Message unsent", bundle: .module) }

    static func workStatus(_ status: HomeWorkStatus) -> String {
        switch status {
        case .running: String(localized: "home.work.running", defaultValue: "Running", bundle: .module)
        case .done: String(localized: "home.work.done", defaultValue: "Done", bundle: .module)
        case .failed: String(localized: "home.work.failed", defaultValue: "Failed", bundle: .module)
        case .waiting: String(localized: "home.work.waiting", defaultValue: "Waiting", bundle: .module)
        }
    }

}

/// Owner labels the App passes into the Home types (localized by this module).
extension HomeConversationSummary {
    /// The owner label of a conversation stored only on this Mac.
    @MainActor public static var thisMacOnlyOwnerLabel: String { HomeStrings.thisMacOnly }
}
