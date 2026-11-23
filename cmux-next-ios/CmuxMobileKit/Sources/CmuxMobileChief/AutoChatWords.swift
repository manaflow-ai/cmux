import Foundation

/// The words of Auto chats on the phone (`plans/cmux-next/auto-mode/DESIGN.md`), the Mac's own
/// for the same states (`plans/cmux-next/auto-mode/UI-NOTES.md`): one place, so the list, the
/// chat and the New Chat sheet say a state the same way. None says how a chat moves.
public enum AutoChatWords {
    /// The feature's name: the section of Cloud chats.
    public static var auto: String { String(localized: "mobile.auto.title", defaultValue: "Auto", bundle: .module) }
    /// Where a chat a Cloud machine runs is.
    public static var cloud: String { String(localized: "mobile.auto.cloud", defaultValue: "Cloud", bundle: .module) }
    public static var runningInCloud: String {
        String(localized: "mobile.auto.runningInCloud", defaultValue: "Running in the Cloud", bundle: .module)
    }
    public static var resuming: String { String(localized: "mobile.auto.resuming", defaultValue: "Resuming…", bundle: .module) }
    public static var comingBack: String {
        String(localized: "mobile.auto.comingBack", defaultValue: "Comes back to your Mac when this turn ends.", bundle: .module)
    }
    public static var onMac: String { String(localized: "mobile.auto.onMac", defaultValue: "On a Mac", bundle: .module) }
    public static var needsMachine: String {
        String(localized: "mobile.auto.needsMachine", defaultValue: "Auto needs a Cloud machine.", bundle: .module)
    }
    public static var newMachine: String {
        String(localized: "mobile.auto.newMachine", defaultValue: "New Cloud Machine…", bundle: .module)
    }
    public static var keepInCloud: String {
        String(localized: "mobile.auto.keepInCloud", defaultValue: "Keep in Cloud", bundle: .module)
    }
    public static var keepFailed: String {
        String(localized: "mobile.auto.keepFailed", defaultValue: "Auto could not be changed.", bundle: .module)
    }
    public static var off: String {
        String(localized: "mobile.auto.off", defaultValue: "Auto is off for this chat.", bundle: .module)
    }
    public static var noChats: String {
        String(localized: "mobile.auto.noChats", defaultValue: "No Auto chats yet.", bundle: .module)
    }
    public static var loadFailed: String {
        String(localized: "mobile.auto.loadFailed", defaultValue: "Couldn't load Auto chats.", bundle: .module)
    }
    public static var retry: String { String(localized: "mobile.auto.retry", defaultValue: "Retry", bundle: .module) }
    public static var newChat: String { String(localized: "mobile.auto.newChat", defaultValue: "New Chat", bundle: .module) }
    public static var repository: String {
        String(localized: "mobile.auto.repository", defaultValue: "Repository", bundle: .module)
    }
    public static var message: String { String(localized: "mobile.auto.message", defaultValue: "Message", bundle: .module) }
    public static var start: String { String(localized: "mobile.auto.start", defaultValue: "Start", bundle: .module) }
    public static var cancel: String { String(localized: "mobile.auto.cancel", defaultValue: "Cancel", bundle: .module) }
    public static var noRecent: String {
        String(localized: "mobile.auto.noRecent",
               defaultValue: "A new chat starts in a repository of one of your Auto chats. Turn on Auto for a chat on your Mac first.",
               bundle: .module)
    }
    public static var startFailed: String {
        String(localized: "mobile.auto.startFailed", defaultValue: "Couldn't start the chat. Try again.", bundle: .module)
    }
    public static var notSent: String {
        String(localized: "mobile.auto.notSent", defaultValue: "Couldn't send. Try again.", bundle: .module)
    }
    public static var textOnly: String {
        String(localized: "mobile.auto.textOnly", defaultValue: "From iPhone, an Auto chat takes text messages only.", bundle: .module)
    }
    public static var unavailable: String {
        String(localized: "mobile.auto.unavailable", defaultValue: "This chat can't be opened.", bundle: .module)
    }
}
