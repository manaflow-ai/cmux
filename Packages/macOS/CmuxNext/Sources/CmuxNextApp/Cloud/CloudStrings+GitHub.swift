import Foundation

/// Set Up GitHub on This Machine. Keys live in Resources/Cloud.xcstrings with every app locale.
/// Nonisolated: ``CloudGitHubSetup`` (nonisolated) reads them.
nonisolated extension CloudStrings {
    static func gitHubConfirmTitle(_ machine: String) -> String {
        String(format: String(localized: "cloud.github.confirmTitle", defaultValue: "Set Up GitHub on %@?", table: "Cloud", bundle: .module), machine)
    }

    static func gitHubConfirmBody(name: String, email: String) -> String {
        String(format: String(localized: "cloud.github.confirmBody",
                              defaultValue: "Sets git user.name to “%1$@” and user.email to “%2$@” on the machine, then starts GitHub sign-in in your browser. Your GitHub token on this Mac is not copied.",
                              table: "Cloud", bundle: .module), name, email)
    }

    static var gitHubConfirmNoIdentity: String {
        String(localized: "cloud.github.confirmNoIdentity",
               defaultValue: "This Mac has no global git user.name or user.email, so only GitHub sign-in starts, in your browser. Your GitHub token on this Mac is not copied.",
               table: "Cloud", bundle: .module)
    }

    /// The confirm when the machine's git will use the cmux GitHub App.
    static func gitHubAppConfirmBody(name: String, email: String) -> String {
        String(format: String(localized: "cloud.github.appConfirmBody",
                              defaultValue: "Sets git user.name to “%1$@” and user.email to “%2$@” on the machine, and lets its git get a short-lived token for each repo from cmux's GitHub App. No GitHub token is stored on the machine.",
                              table: "Cloud", bundle: .module), name, email)
    }

    static var gitHubAppConfirmNoIdentity: String {
        String(localized: "cloud.github.appConfirmNoIdentity",
               defaultValue: "This Mac has no global git user.name or user.email, so only GitHub is set up: the machine's git gets a short-lived token for each repo from cmux's GitHub App. No GitHub token is stored on the machine.",
               table: "Cloud", bundle: .module)
    }

    static var gitHubAppReady: String {
        String(localized: "cloud.github.appReady",
               defaultValue: "GitHub is set up through cmux's GitHub App: git on this machine gets a short-lived token for each repo, and none is stored there. For the GitHub CLI, run cmux github gh.",
               table: "Cloud", bundle: .module)
    }

    /// Why the machine signs in to GitHub itself instead of using the App, in plain words.
    static func gitHubFallback(_ reason: CloudGitHubSetup.Fallback) -> String {
        switch reason {
        case .notConnected:
            String(localized: "cloud.github.fallbackNotConnected",
                   defaultValue: "Your team hasn't connected cmux's GitHub App, so this machine signs in to GitHub itself and keeps that token until you sign out there.",
                   table: "Cloud", bundle: .module)
        case .notConfigured:
            String(localized: "cloud.github.fallbackNotConfigured",
                   defaultValue: "cmux's GitHub App isn't available here, so this machine signs in to GitHub itself and keeps that token until you sign out there.",
                   table: "Cloud", bundle: .module)
        case .unknown:
            String(localized: "cloud.github.fallbackUnknown",
                   defaultValue: "cmux couldn't check its GitHub App, so this machine signs in to GitHub itself and keeps that token until you sign out there.",
                   table: "Cloud", bundle: .module)
        case .notOnMachine:
            String(localized: "cloud.github.fallbackNotOnMachine",
                   defaultValue: "This machine can't use cmux's GitHub App yet, so it signs in to GitHub itself and keeps that token until you sign out there.",
                   table: "Cloud", bundle: .module)
        }
    }

    static var gitHubSetUp: String {
        String(localized: "cloud.github.setUp", defaultValue: "Set Up", table: "Cloud", bundle: .module)
    }

    static var gitHubSetupTitle: String {
        String(localized: "cloud.github.title", defaultValue: "GitHub Setup", table: "Cloud", bundle: .module)
    }

    static func gitHubEnterCode(_ code: String) -> String {
        String(format: String(localized: "cloud.github.enterCode",
                              defaultValue: "Enter code %@ at github.com/login/device to finish. The code is copied.",
                              table: "Cloud", bundle: .module), code)
    }

    static var gitHubAlreadySignedIn: String {
        String(localized: "cloud.github.alreadySignedIn", defaultValue: "GitHub is already signed in on this machine.", table: "Cloud", bundle: .module)
    }

    static var gitHubMissing: String {
        String(localized: "cloud.github.missing", defaultValue: "The GitHub CLI isn't installed on this machine. Install gh on it, then run `cmux cloud setup-github --target machine:<id>` again.", table: "Cloud", bundle: .module)
    }

    static var gitHubFailed: String {
        String(localized: "cloud.github.failed", defaultValue: "GitHub sign-in didn't start on this machine. Run `cmux cloud setup-github --target machine:<id>` again.", table: "Cloud", bundle: .module)
    }

    static var gitHubIdentityFailed: String {
        String(localized: "cloud.github.identityFailed", defaultValue: "Git identity couldn't be set on this machine.", table: "Cloud", bundle: .module)
    }

    static var gitHubIdentityUnsafe: String {
        String(localized: "cloud.github.identityUnsafe",
               defaultValue: "Your git user.name or user.email has control characters or is too long, so cmux won't pass it on.",
               table: "Cloud", bundle: .module)
    }
}
