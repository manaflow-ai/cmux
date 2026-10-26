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
