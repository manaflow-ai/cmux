import CmuxHomeCore
import Foundation

/// Every user-facing string of the Home module (Localizable.xcstrings).
enum HomeStrings {
    static var thisMacOnly: String { String(localized: "home.owner.thisMac", defaultValue: "This Mac only", bundle: .module) }
    static var copyMessage: String { String(localized: "home.menu.copy", defaultValue: "Copy", bundle: .module) }
    static var attachFiles: String { String(localized: "home.composer.attach", defaultValue: "Attach Files", bundle: .module) }
    static var attachPrompt: String { String(localized: "home.composer.attach.prompt", defaultValue: "Attach", bundle: .module) }
    static var removeAttachment: String {
        String(localized: "home.composer.attach.remove", defaultValue: "Remove Attachment", bundle: .module)
    }
    static var pastedItem: String { String(localized: "home.composer.attach.pasted", defaultValue: "Pasted item", bundle: .module) }
    static var attachFailed: String {
        String(localized: "home.composer.attach.failed", defaultValue: "The file couldn’t be attached.", bundle: .module)
    }
    static func attachUnsupported(_ name: String) -> String {
        String(format: String(localized: "home.composer.attach.unsupported",
                              defaultValue: "“%@” can’t be attached. You can attach photos, videos, audio, PDFs, text files and ZIP archives.",
                              bundle: .module), name)
    }
    static func attachTooLarge(_ name: String) -> String {
        String(format: String(localized: "home.composer.attach.tooLarge", defaultValue: "“%@” is larger than 100 MB.", bundle: .module), name)
    }
    static func attachTooLargeAny() -> String {
        String(localized: "home.composer.attach.tooLargeAny", defaultValue: "A file is larger than 100 MB.", bundle: .module)
    }
    static func attachEmpty(_ name: String) -> String {
        String(format: String(localized: "home.composer.attach.empty", defaultValue: "“%@” is empty.", bundle: .module), name)
    }
    static func attachInvalidName(_ name: String) -> String {
        String(format: String(localized: "home.composer.attach.invalidName", defaultValue: "“%@” is not a valid file name.",
                              bundle: .module), name)
    }
    static func attachLocationNotRemoved(_ name: String) -> String {
        String(format: String(localized: "home.composer.attach.locationNotRemoved",
                              defaultValue: "Location data couldn’t be removed from “%@”, so it was not attached.", bundle: .module), name)
    }
    /// Why a send shows "Not Delivered": attachments to an owner that
    /// stores none, else the refusal's own notice.
    static func notDeliveredReason(_ rejection: HomeRejection) -> String {
        if rejection == .invalid("attachments unsupported") {
            return String(localized: "home.send.attachmentsUnsupported", defaultValue: "This conversation can’t receive attachments yet.",
                          bundle: .module)
        }
        return Self.rejection(rejection)
    }
    static var unanswered: String {
        String(localized: "home.send.unanswered", defaultValue: "A change may not have gone through. Check your connection.",
               bundle: .module)
    }
    static var cancelUpload: String { String(localized: "home.menu.cancelUpload", defaultValue: "Cancel Upload", bundle: .module) }
    /// The composer notice for a send the owner refused after it left the
    /// composer (a resumed upload, a resend).
    static func rejection(_ rejection: HomeRejection) -> String {
        switch rejection {
        case .notAuthorized:
            String(localized: "home.send.refused.notAuthorized", defaultValue: "You can’t send messages in this conversation.",
                   bundle: .module)
        case .rateLimited:
            String(localized: "home.send.refused.rateLimited", defaultValue: "Too many messages. Try again in a moment.", bundle: .module)
        case .ownerUnreachable, .indeterminate, .invalid:
            String(localized: "home.send.refused.generic", defaultValue: "A message couldn’t be sent.", bundle: .module)
        }
    }
    static func attachTooMany(_ limit: Int) -> String {
        String(format: String(localized: "home.composer.attach.tooMany", defaultValue: "Too many attachments. Limit: %lld.",
                              bundle: .module), limit)
    }
    /// The notice for each reason the data side refuses an attachment.
    static func attachmentRefusal(_ refusal: HomeAttachmentError, name: String? = nil) -> String {
        switch refusal {
        case .typeRefused(_, let file): attachUnsupported(name ?? file)
        case .tooLarge: name.map(attachTooLarge) ?? attachTooLargeAny()
        case .empty(let file): attachEmpty(name ?? file)
        case .invalidName(let file): attachInvalidName(name ?? file)
        case .locationNotRemoved(let file): attachLocationNotRemoved(name ?? file)
        case .tooManyParts(let limit): attachTooMany(limit - 1)
        }
    }
    static var playVideo: String { String(localized: "home.video.play", defaultValue: "Play Video", bundle: .module) }
    static var pauseVideo: String { String(localized: "home.video.pause", defaultValue: "Pause Video", bundle: .module) }
    static var firstRunOpenTerminal: String {
        String(localized: "home.firstRun.openTerminal", defaultValue: "Open a terminal", bundle: .module)
    }
    static var firstRunStartAgent: String {
        String(localized: "home.firstRun.startAgent", defaultValue: "Start an agent", bundle: .module)
    }
    /// The keyboard hint under the first-run rows; `keys` is the tab family's
    /// shortcut as the registry shows it (`⌃1…9`).
    static func firstRunTabsHint(_ keys: String) -> String {
        String(format: String(localized: "home.firstRun.tabsHint", defaultValue: "%@ switches tabs.", bundle: .module), keys)
    }
    static var firstRunSuggestion: String {
        String(localized: "home.firstRun.suggestion", defaultValue: "What are my agents doing right now?", bundle: .module)
    }
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
