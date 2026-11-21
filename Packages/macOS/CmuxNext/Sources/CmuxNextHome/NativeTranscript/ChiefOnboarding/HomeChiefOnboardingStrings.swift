import CmuxNextHomeModel
import Foundation

/// Meet Chief's words (``HomeChiefOnboardingCard``), in the Home module's catalog.
enum HomeChiefOnboardingStrings {
    static func progress(_ step: Int, of count: Int) -> String {
        String(format: String(localized: "home.chiefOnboarding.progress", defaultValue: "Step %1$d of %2$d", bundle: .module), step, count)
    }
    static var skip: String { String(localized: "home.chiefOnboarding.skip", defaultValue: "Skip", bundle: .module) }
    static var back: String { String(localized: "home.chiefOnboarding.back", defaultValue: "Back", bundle: .module) }
    static var next: String { String(localized: "home.chiefOnboarding.next", defaultValue: "Continue", bundle: .module) }
    static var start: String { String(localized: "home.chiefOnboarding.start", defaultValue: "Start chatting", bundle: .module) }

    static func title(_ step: ChiefOnboardingStep) -> String {
        switch step {
        case .meet: String(localized: "home.chiefOnboarding.meet.title", defaultValue: "Meet Chief", bundle: .module)
        case .access: String(localized: "home.chiefOnboarding.access.title", defaultValue: "What Chief can do", bundle: .module)
        case .look: String(localized: "home.chiefOnboarding.look.title", defaultValue: "Make it comfortable", bundle: .module)
        }
    }

    static func body(_ step: ChiefOnboardingStep) -> String {
        switch step {
        case .meet:
            String(localized: "home.chiefOnboarding.meet.body",
                   defaultValue: "Chief is your assistant in cmux. Tell it what you want done, in plain words. It works only for you.",
                   bundle: .module)
        case .access:
            String(localized: "home.chiefOnboarding.access.body",
                   defaultValue: "Chief runs commands, edits files and uses the cmux browser on this Mac, as you. Pick how often it checks with you first.",
                   bundle: .module)
        case .look:
            String(localized: "home.chiefOnboarding.look.body",
                   defaultValue: "Pick how roomy cmux looks and how large its text is. Changes show right away.", bundle: .module)
        }
    }

    // What Chief does (the first step).
    static var agentsTitle: String { String(localized: "home.chiefOnboarding.agents.title", defaultValue: "Runs agents for you", bundle: .module) }
    static var agentsDetail: String {
        String(localized: "home.chiefOnboarding.agents.detail",
               defaultValue: "Bigger jobs go to coding agents, each in its own workspace you can watch and join.", bundle: .module)
    }
    static var memoryTitle: String { String(localized: "home.chiefOnboarding.memory.title", defaultValue: "Remembers what matters", bundle: .module) }
    static var memoryDetail: String {
        String(localized: "home.chiefOnboarding.memory.detail",
               defaultValue: "Your preferences, projects and decisions, so you don’t repeat yourself. You can see and edit what it keeps.",
               bundle: .module)
    }
    static var followUpTitle: String { String(localized: "home.chiefOnboarding.followUp.title", defaultValue: "Follows up", bundle: .module) }
    static var followUpDetail: String {
        String(localized: "home.chiefOnboarding.followUp.detail",
               defaultValue: "It checks on agents and builds, and tells you here when something is done or needs you.", bundle: .module)
    }

    // What Chief may do (the second step). The modes' names are Settings' own (``SettingsSchema``).
    static func modeDetail(_ mode: ChiefPermissionMode) -> String {
        switch mode {
        case .bypass:
            String(localized: "home.chiefOnboarding.mode.bypass", defaultValue: "Runs every command without asking. The default.", bundle: .module)
        case .auto:
            String(localized: "home.chiefOnboarding.mode.auto",
                   defaultValue: "A safety check approves each command and stops risky ones.", bundle: .module)
        case .manual:
            String(localized: "home.chiefOnboarding.mode.manual",
                   defaultValue: "Skips anything that needs approval and tells you instead.", bundle: .module)
        }
    }
    /// Chief's own rule (its prompt), in every mode; only Auto and Manual also check commands.
    static var toldToAsk: String {
        String(localized: "home.chiefOnboarding.toldToAsk",
               defaultValue: "Chief is told to ask before spending money, deleting data or signing in, and never to type passwords. A rule, not a lock.",
               bundle: .module)
    }
    static var changeLater: String {
        String(localized: "home.chiefOnboarding.changeLater", defaultValue: "Change it any time in Settings › Home.", bundle: .module)
    }
    static var openSettings: String { String(localized: "home.chiefOnboarding.openSettings", defaultValue: "Open Settings", bundle: .module) }
    static var managed: String {
        String(localized: "home.chiefOnboarding.managed", defaultValue: "Your organization sets this.", bundle: .module)
    }
    static var writeFailed: String {
        String(localized: "home.chiefOnboarding.writeFailed",
               defaultValue: "That didn’t save. Try again, or change it in Settings.", bundle: .module)
    }

    // How cmux looks (the last step). The densities' names are Settings' own (``SettingsSchema``).
    static var densityLabel: String { String(localized: "home.chiefOnboarding.density", defaultValue: "Density", bundle: .module) }
    static var textSizeLabel: String { String(localized: "home.chiefOnboarding.textSize", defaultValue: "Text size", bundle: .module) }
    /// The text size, a bare number in the person's locale (its label says what it is).
    static func points(_ size: Int) -> String { size.formatted() }
    static var smaller: String { String(localized: "home.chiefOnboarding.smaller", defaultValue: "Smaller text", bundle: .module) }
    static var larger: String { String(localized: "home.chiefOnboarding.larger", defaultValue: "Larger text", bundle: .module) }
    static var lookLater: String {
        String(localized: "home.chiefOnboarding.lookLater", defaultValue: "More in Settings › Appearance.", bundle: .module)
    }
}
