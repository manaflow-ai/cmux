import Foundation

/// Every user-facing string of the Home module (Localizable.xcstrings). The
/// transcript's own strings are MessagesLab's (CmuxMessagesLab's catalogs).
enum HomeStrings {
    static var firstRunTitle: String {
        String(localized: "home.firstRun.title", defaultValue: "Chief runs your agents on this Mac.", bundle: .module)
    }
    static var firstRunBody: String {
        String(localized: "home.firstRun.body", defaultValue: "Ask it to start work, check on your agents, or answer what they need.", bundle: .module)
    }
    static var memoryDeviceOnly: String {
        String(localized: "home.chief.memoryScope.deviceOnly", defaultValue: "This Chief remembers on this device only.", bundle: .module)
    }
    static var firstRunSuggestion: String {
        String(localized: "home.firstRun.suggestion", defaultValue: "What are my agents doing right now?", bundle: .module)
    }
    static var conversations: String { String(localized: "home.list.title", defaultValue: "Conversations", bundle: .module) }
}
