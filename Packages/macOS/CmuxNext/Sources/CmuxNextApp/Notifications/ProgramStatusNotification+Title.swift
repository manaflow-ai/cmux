import CmuxNextBridge
import CmuxNextCompat
import Foundation

extension ProgramStatusNotification {
    /// The banner title in `localizations` (cx-6so.36.8): built from the matched record like the
    /// daemon's English "<title, else app, else A program> <verb>" (program_status.rs
    /// `raise_alert`), which stays the title of a notification with no record.
    func title(localizations: [String]) -> String {
        func text(_ key: String, _ english: String) -> String {
            Bundle.module.localizedString(forKey: "notifications.programAlert.\(key)", value: english, table: "NotificationsPanel",
                                          preferredLocalizations: localizations)
        }
        let name = record.title ?? record.app ?? text("aProgram", "A program")
        let format = switch reason {
        case .permission: text("needsApproval", "%@ needs approval")
        case .question: text("asksQuestion", "%@ asks a question")
        case .auth: text("needsSignIn", "%@ needs sign-in")
        case .input: text("needsInput", "%@ needs input")
        case .failed: text("failed", "%@ failed")
        case .done: text("done", "%@ is done")
        }
        return String(format: format, name)
    }
}
