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

    /// The reply box's placeholder for the chat the mini shows (Show in Mini).
    static func message(_ title: String) -> String {
        String(localized: "chiefPet.reply.message", defaultValue: "Message \(title)", table: "ChiefPet", bundle: .module)
    }

    /// The latest reply line's control: unfolds the whole reply, and folds it again.
    static var showMore: String {
        String(localized: "chiefPet.reply.showMore", defaultValue: "Show More", table: "ChiefPet", bundle: .module)
    }

    static var showLess: String {
        String(localized: "chiefPet.reply.showLess", defaultValue: "Show Less", table: "ChiefPet", bundle: .module)
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

    // MARK: Upload (ChiefAvatarUploads)

    static var uploadChoose: String {
        String(localized: "chiefPet.upload.choose", defaultValue: "Upload Your Own…", table: "ChiefPet", bundle: .module)
    }

    static var uploadYours: String {
        String(localized: "chiefPet.upload.yours", defaultValue: "Your Upload", table: "ChiefPet", bundle: .module)
    }

    static var uploadRemove: String {
        String(localized: "chiefPet.upload.remove", defaultValue: "Remove Upload", table: "ChiefPet", bundle: .module)
    }

    static var uploadDropHint: String {
        String(localized: "chiefPet.upload.dropHint", defaultValue: "Drop a picture or GIF here to use your own.", table: "ChiefPet", bundle: .module)
    }

    static var uploadLimits: String {
        String(localized: "chiefPet.upload.limits",
               defaultValue: "Use a PNG, JPEG, WebP, HEIC or GIF up to 20 MB. A moving GIF can be at most 512 KB and 256 × 256 pixels.",
               table: "ChiefPet", bundle: .module)
    }

    static var uploadUnsaved: String {
        String(localized: "chiefPet.upload.unsaved", defaultValue: "cmux couldn’t save that picture on this Mac.", table: "ChiefPet", bundle: .module)
    }
}

/// The upload's text for the Chief Settings popover, which lives in another module.
extension ChiefAvatarUploads {
    public static var chooseTitle: String { ChiefPetStrings.uploadChoose }
    public static var yoursTitle: String { ChiefPetStrings.uploadYours }
    public static var removeTitle: String { ChiefPetStrings.uploadRemove }
    public static var dropHint: String { ChiefPetStrings.uploadDropHint }
}

/// Show in Mini's text (`ChiefPetMini`, which lives in another module).
extension ChiefPetSubject {
    /// The refusal when Show in Mini runs with no agent chat focused.
    public static var needsAgentChatTitle: String {
        String(localized: "chiefPet.mini.needsAgentChat", defaultValue: "Show in Mini works in agent chats. Focus one first.", table: "ChiefPet", bundle: .module)
    }

    /// Show in Mini's palette title while the mini already shows the focused chat.
    public static var showChiefTitle: String {
        String(localized: "chiefPet.mini.showChief", defaultValue: "Show Chief in Mini", table: "ChiefPet", bundle: .module)
    }
}
