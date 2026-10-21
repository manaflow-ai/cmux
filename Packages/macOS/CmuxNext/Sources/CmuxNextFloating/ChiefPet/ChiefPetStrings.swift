import Foundation

/// Text of the Chief pet. Keys live in Resources/ChiefPet.xcstrings.
enum ChiefPetStrings {
    static var accessibilityLabel: String {
        String(localized: "chiefPet.accessibilityLabel", defaultValue: "Chief", table: "ChiefPet", bundle: .module)
    }

    static var expand: String {
        String(localized: "chiefPet.expand", defaultValue: "Show Chief", table: "ChiefPet", bundle: .module)
    }

    static var compose: String {
        String(localized: "chiefPet.compose", defaultValue: "New Message", table: "ChiefPet", bundle: .module)
    }

    static var messageChief: String {
        String(localized: "chiefPet.reply.messageChief", defaultValue: "Message Chief", table: "ChiefPet", bundle: .module)
    }

    static func reply(to title: String) -> String {
        String(localized: "chiefPet.reply.replyTo", defaultValue: "Reply to \(title)", table: "ChiefPet", bundle: .module)
    }

    static func returnOpens(_ title: String) -> String {
        String(localized: "chiefPet.reply.returnOpens", defaultValue: "Return opens \(title)", table: "ChiefPet", bundle: .module)
    }

    static var settings: String {
        String(localized: "chiefPet.menu.settings", defaultValue: "Chief Pet Settings…", table: "ChiefPet", bundle: .module)
    }

    static var hide: String {
        String(localized: "chiefPet.menu.hide", defaultValue: "Hide Chief Pet", table: "ChiefPet", bundle: .module)
    }

    /// A notice whose poster gave no title: the tab's name and what happened there.
    static func finished(_ name: String) -> String {
        String(localized: "chiefPet.notice.finished", defaultValue: "\(name) finished", table: "ChiefPet", bundle: .module)
    }

    static func needsYou(_ name: String) -> String {
        String(localized: "chiefPet.notice.needsYou", defaultValue: "\(name) needs your input", table: "ChiefPet", bundle: .module)
    }

    static func failed(_ name: String) -> String {
        String(localized: "chiefPet.notice.failed", defaultValue: "\(name) failed", table: "ChiefPet", bundle: .module)
    }

    static var replyTarget: String {
        String(localized: "chiefPet.reply.target", defaultValue: "Send to", table: "ChiefPet", bundle: .module)
    }
}
