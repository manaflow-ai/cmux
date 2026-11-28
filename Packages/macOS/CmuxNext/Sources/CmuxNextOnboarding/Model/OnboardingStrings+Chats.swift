import Foundation

/// The chats step's text.
extension OnboardingStrings {
    static var chatsTitle: String { String(localized: "onboarding.chats.title", defaultValue: "Pick up your chats", bundle: .module) }
    static var chatsScanning: String { String(localized: "onboarding.chats.scanning", defaultValue: "Looking for chats…", bundle: .module) }
    static var chatsEmpty: String {
        String(localized: "onboarding.chats.empty", defaultValue: "No Claude Code or Codex chats on this Mac yet.", bundle: .module)
    }
    static var chatsUntitled: String { String(localized: "onboarding.chats.untitled", defaultValue: "Untitled chat", bundle: .module) }
    static var chatsKeys: String {
        String(localized: "onboarding.chats.keys", defaultValue: "↑ ↓ move · Space checks a chat", bundle: .module)
    }
    static func chatsPrompts(_ count: Int) -> String {
        String(format: String(localized: "onboarding.chats.prompts", defaultValue: "Prompts: %lld", bundle: .module), count)
    }
}
