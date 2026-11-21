import Foundation

/// The first-run Agents step's text.
extension OnboardingStrings {
    /// The window's title in the Window menu and for VoiceOver.
    static var agentsTitle: String { String(localized: "onboarding.agents.title", defaultValue: "Agents", bundle: .module) }
    static var agentsHeading: String {
        String(localized: "onboarding.agents.heading", defaultValue: "Sign In to Your Agents", bundle: .module)
    }
    static var agentsBody: String {
        String(localized: "onboarding.agents.body",
               defaultValue: "Sign in to the agent CLIs you use. You can also do this later in Settings.", bundle: .module)
    }
    static var agentsChecking: String { String(localized: "onboarding.agents.checking", defaultValue: "Checking…", bundle: .module) }
    static var agentsNone: String {
        String(localized: "onboarding.agents.none", defaultValue: "No agent CLIs found on this Mac.", bundle: .module)
    }
    static var agentsSignIn: String { String(localized: "onboarding.agents.signIn", defaultValue: "Sign In", bundle: .module) }
    /// Sign In's VoiceOver label, naming the agent ("Sign In to Codex").
    static func agentsSignInNamed(_ name: String) -> String {
        String(format: String(localized: "onboarding.agents.signIn.named", defaultValue: "Sign In to %@", bundle: .module), name)
    }
    /// The line under the list once a Sign In opened its terminal tab.
    static var agentsSignInRunning: String {
        String(localized: "onboarding.agents.signIn.running",
               defaultValue: "Finish signing in in the terminal tab, then come back here.", bundle: .module)
    }
    static var agentsSignInFailed: String {
        String(localized: "onboarding.agents.signIn.failed",
               defaultValue: "Couldn’t open a terminal tab to sign in.", bundle: .module)
    }
    static func agentsAuth(_ auth: OnboardingAgent.Auth) -> String {
        switch auth {
        case .signedIn: String(localized: "onboarding.agents.auth.signedIn", defaultValue: "Signed in", bundle: .module)
        case .signedOut: String(localized: "onboarding.agents.auth.signedOut", defaultValue: "Not signed in", bundle: .module)
        case .expired: String(localized: "onboarding.agents.auth.expired", defaultValue: "Sign-in expired", bundle: .module)
        case .unknown: String(localized: "onboarding.agents.auth.unknown", defaultValue: "Sign-in not checked", bundle: .module)
        }
    }
}
