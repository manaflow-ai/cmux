import Foundation

/// The Pair Another Machine card's words (Resources/PairInvite.xcstrings), and Add Server's it shares
/// (Resources/Localizable.xcstrings, `approver.*`).
nonisolated enum PairInviteStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "PairInvite", bundle: .localizedModule)
    }

    private static func approver(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .localizedModule)
    }

    static var title: String { t("pairInvite.title", "Pair Another Machine") }
    static var help: String { t("pairInvite.help", "On the other machine, run this line in a terminal. No SSH needed. You confirm it here.") }
    static var minting: String { t("pairInvite.minting", "Making a code…") }
    static var installHelp: String { t("pairInvite.installHelp", "No cmux there yet? This line installs it, then pairs:") }
    static var scan: String { t("pairInvite.scan", "Or scan it with a phone or a laptop camera.") }
    static var once: String { t("pairInvite.once", "It works once, on one machine.") }
    static var expiresIn: String { t("pairInvite.expiresIn", "Expires in %@") }
    static var waiting: String { t("pairInvite.waiting", "Waiting for the machine. This card changes when it uses the code.") }
    static var lookingUp: String { t("pairInvite.lookingUp", "A machine used the code. Reading its details…") }
    static var arrived: String { t("pairInvite.arrived", "A machine used your code") }
    static var confirmNote: String { t("pairInvite.confirmNote", "Click Confirm to pair it. Only a click pairs it, never a key or a script.") }
    static func paired(_ name: String) -> String { String(format: t("pairInvite.paired", "%@ paired"), name) }
    static var pairedDetail: String { t("pairInvite.pairedDetail", "It is paired with your team.") }
    static var voided: String {
        t("pairInvite.voided", "A second machine used this code, so nothing was paired and the code no longer works. Make a new code and use it on one machine only.")
    }
    static var expired: String { t("pairInvite.expired", "That code expired before a machine used it. Make a new one.") }
    static var lost: String { t("pairInvite.lost", "The connection to cmux dropped while waiting. Make a new code.") }
    static var signedOut: String { t("pairInvite.signedOut", "Sign in to cmux to pair another machine.") }
    static var copyCode: String { t("pairInvite.copyCode", "Copy Code") }
    static var copyLine: String { t("pairInvite.copyLine", "Copy Line") }
    static var copyInstallLine: String { t("pairInvite.copyInstallLine", "Copy Install Line") }
    static var confirm: String { t("pairInvite.confirm", "Confirm") }
    static var newCode: String { t("pairInvite.newCode", "New Code") }
    static var copied: String { t("pairInvite.copied", "Copied") }

    static var cancel: String { approver("approver.cancel", "Cancel") }
    static var done: String { approver("approver.done", "Done") }
    static var retry: String { approver("approver.retry", "Try Again") }
    static var adding: String { approver("approver.adding", "Adding…") }
    static var name: String { approver("approver.name", "Name") }
    static var runChief: String { approver("approver.runChief", "Run my Chief on this server") }
    static var wordsQuestion: String { approver("approver.wordsQuestion", "Do these words match the server?") }
    static var wordsWarning: String { approver("approver.wordsWarning", "If any word differs, deny. Someone else's server could be using this code.") }
}
