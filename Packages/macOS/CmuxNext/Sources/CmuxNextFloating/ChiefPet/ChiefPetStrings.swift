import Foundation

/// Text of the Chief pet. Keys live in Resources/ChiefPet.xcstrings.
enum ChiefPetStrings {
    static var accessibilityLabel: String {
        String(localized: "chiefPet.accessibilityLabel", defaultValue: "Chief", table: "ChiefPet", bundle: .module)
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

    static var replyTarget: String {
        String(localized: "chiefPet.reply.target", defaultValue: "Send to", table: "ChiefPet", bundle: .module)
    }
}
