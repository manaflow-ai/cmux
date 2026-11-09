import Foundation

/// The sidebar's "Finish setting up" card (``SetupCardPageProvider/checklist``).
extension OnboardingStrings {
    static var setupTitle: String { String(localized: "setup.title", defaultValue: "Finish setting up", bundle: .module) }
    /// The x's tooltip and VoiceOver label.
    static var setupHide: String { String(localized: "setup.hide", defaultValue: "Hide Setup", bundle: .module) }
    /// "1 of 4": steps done of steps shown.
    static func setupProgress(_ done: Int, _ total: Int) -> String {
        String(format: String(localized: "setup.progress", defaultValue: "%1$lld of %2$lld", bundle: .module), done, total)
    }
    /// "Install Claude Code".
    static func setupInstallAgent(_ name: String) -> String {
        String(format: String(localized: "setup.installAgent", defaultValue: "Install %@", bundle: .module), name)
    }
    /// "Sign In to Claude Code", "Sign In to cmux".
    static func setupSignInTo(_ name: String) -> String {
        String(format: String(localized: "setup.signInTo", defaultValue: "Sign In to %@", bundle: .module), name)
    }
    /// The button while an agent's login waits for the person to say it finished.
    static var setupConfirmSignedIn: String { String(localized: "setup.confirmSignedIn", defaultValue: "I’m Signed In", bundle: .module) }
    static func setupAgentUnverified(_ name: String) -> String {
        String(format: String(localized: "setup.agents.unverified", defaultValue: "Finish signing in to %@ in its terminal tab", bundle: .module), name)
    }
    static func setupAgentFailed(_ name: String) -> String {
        String(format: String(localized: "setup.agents.failed", defaultValue: "%@ did not install", bundle: .module), name)
    }
    static var setupHistory: String { String(localized: "setup.history", defaultValue: "Import Chat History", bundle: .module) }
    static var setupHistoryDetail: String {
        String(localized: "setup.history.detail", defaultValue: "Chats from Claude Code and Codex", bundle: .module)
    }
    static var setupAccountDetail: String {
        String(localized: "setup.account.detail", defaultValue: "Your phone, Cloud machines and sync", bundle: .module)
    }
    static var setupCLI: String { String(localized: "setup.cli", defaultValue: "Install the cmux Command", bundle: .module) }
    static var setupCLIReplace: String { String(localized: "setup.cli.replace", defaultValue: "Replace the cmux Command", bundle: .module) }
    static var setupCLIDetail: String { String(localized: "setup.cli.detail", defaultValue: "cmux in any terminal", bundle: .module) }
    static var setupCLIOther: String {
        String(localized: "setup.cli.other", defaultValue: "cmux in Terminal opens another copy", bundle: .module)
    }
    static var setupCLIForeign: String {
        String(localized: "setup.cli.foreign", defaultValue: "Another cmux command is on your PATH", bundle: .module)
    }
    static var setupCLIFromImage: String {
        String(localized: "setup.cli.fromImage", defaultValue: "Open cmux from Applications to install it", bundle: .module)
    }
}
