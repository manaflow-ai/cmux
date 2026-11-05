import Foundation

/// Text of the Pair Another Machine card (Resources/PairInvite.xcstrings). The facts, the words
/// question and warning, the name and Cancel are Add Server's own (``ServerStrings``).
enum PairInviteStrings {
    private static func s(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "PairInvite", bundle: .module)
    }

    static var title: String { s("pairInvite.title", "Pair Another Machine") }
    static var help: String {
        s("pairInvite.help", "On the other machine, run this line in a terminal. No SSH needed. You confirm it here.")
    }
    static var minting: String { s("pairInvite.minting", "Making a code…") }
    static var installHelp: String { s("pairInvite.installHelp", "No cmux there yet? This line installs it, then pairs:") }
    static var scan: String { s("pairInvite.scan", "Or scan it with a phone or a laptop camera.") }
    static var once: String { s("pairInvite.once", "It works once, on one machine.") }
    static func expires(_ seconds: Int) -> String {
        let clock = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return String(format: s("pairInvite.expiresIn", "Expires in %@"), clock)
    }
    static var waiting: String { s("pairInvite.waiting", "Waiting for the machine. This card changes when it uses the code.") }
    static var lookingUp: String { s("pairInvite.lookingUp", "A machine used the code. Reading its details…") }
    static var arrived: String { s("pairInvite.arrived", "A machine used your code") }
    static var confirmNote: String { s("pairInvite.confirmNote", "Click Confirm to pair it. Only a click pairs it, never a key or a script.") }
    static func paired(_ name: String) -> String { String(format: s("pairInvite.paired", "%@ paired"), name) }
    static var pairedDetail: String { s("pairInvite.pairedDetail", "It is paired with your team.") }
    static var voided: String {
        s("pairInvite.voided", "A second machine used this code, so nothing was paired and the code no longer works. Make a new code and use it on one machine only.")
    }
    static var expired: String { s("pairInvite.expired", "That code expired before a machine used it. Make a new one.") }
    static var lost: String { s("pairInvite.lost", "The connection to cmux dropped while waiting. Make a new code.") }
    static var signedOut: String { s("pairInvite.signedOut", "Sign in to cmux to pair another machine.") }

    static func button(_ action: PairInviteAction, copied: PairInviteModel.CopyTarget?) -> String {
        switch action {
        case .copyCode: copied == .code ? copiedTitle : s("pairInvite.copyCode", "Copy Code")
        case .copyLine: copied == .line ? copiedTitle : s("pairInvite.copyLine", "Copy Line")
        case .copyInstallLine: copied == .installLine ? copiedTitle : s("pairInvite.copyInstallLine", "Copy Install Line")
        case .confirm: s("pairInvite.confirm", "Confirm")
        case .retry: ServerStrings.tryAgain
        case .newCode: s("pairInvite.newCode", "New Code")
        case .done: ServerStrings.done
        case .cancel: ServerStrings.cancel
        }
    }

    private static var copiedTitle: String { s("pairInvite.copied", "Copied") }
}
