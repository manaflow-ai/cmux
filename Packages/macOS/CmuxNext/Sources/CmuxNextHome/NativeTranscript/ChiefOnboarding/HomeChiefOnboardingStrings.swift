import CmuxNextHomeModel
import Foundation

/// Meet Chief's words (``HomeChiefOnboardingCard``), in the Home module's catalog.
enum HomeChiefOnboardingStrings {
    static func progress(_ step: Int, of count: Int) -> String {
        String(format: String(localized: "home.chiefOnboarding.progress", defaultValue: "Step %1$d of %2$d", bundle: .localizedModule), step, count)
    }
    static var skip: String { String(localized: "home.chiefOnboarding.skip", defaultValue: "Skip", bundle: .localizedModule) }
    static var back: String { String(localized: "home.chiefOnboarding.back", defaultValue: "Back", bundle: .localizedModule) }
    static var next: String { String(localized: "home.chiefOnboarding.next", defaultValue: "Continue", bundle: .localizedModule) }
    static var start: String { String(localized: "home.chiefOnboarding.start", defaultValue: "Start chatting", bundle: .localizedModule) }

    static func title(_ step: ChiefOnboardingStep) -> String {
        switch step {
        case .meet: String(localized: "home.chiefOnboarding.meet.title", defaultValue: "Meet Chief", bundle: .localizedModule)
        case .access: String(localized: "home.chiefOnboarding.access.title", defaultValue: "What Chief can do", bundle: .localizedModule)
        case .look: String(localized: "home.chiefOnboarding.look.title", defaultValue: "Make it comfortable", bundle: .localizedModule)
        }
    }

    static func body(_ step: ChiefOnboardingStep) -> String {
        switch step {
        case .meet:
            String(localized: "home.chiefOnboarding.meet.body",
                   defaultValue: "Chief is your assistant in cmux. Tell it what you want done, in plain words. It works only for you.",
                   bundle: .localizedModule)
        case .access:
            String(localized: "home.chiefOnboarding.access.body",
                   defaultValue: "Chief runs commands, edits files and uses the cmux browser on this Mac, as you. Pick how often it checks with you first.",
                   bundle: .localizedModule)
        case .look:
            String(localized: "home.chiefOnboarding.look.body",
                   defaultValue: "Pick how roomy cmux looks and how large its text is. Changes show right away.", bundle: .localizedModule)
        }
    }

    // What Chief does (the first step).
    static var agentsTitle: String { String(localized: "home.chiefOnboarding.agents.title", defaultValue: "Runs agents for you", bundle: .localizedModule) }
    static var agentsDetail: String {
        String(localized: "home.chiefOnboarding.agents.detail",
               defaultValue: "Bigger jobs go to coding agents, each in its own workspace you can watch and join.", bundle: .localizedModule)
    }
    static var memoryTitle: String { String(localized: "home.chiefOnboarding.memory.title", defaultValue: "Remembers what matters", bundle: .localizedModule) }
    static var memoryDetail: String {
        String(localized: "home.chiefOnboarding.memory.detail",
               defaultValue: "Your preferences, projects and decisions, so you don’t repeat yourself. You can see and edit what it keeps.",
               bundle: .localizedModule)
    }
    static var followUpTitle: String { String(localized: "home.chiefOnboarding.followUp.title", defaultValue: "Follows up", bundle: .localizedModule) }
    static var followUpDetail: String {
        String(localized: "home.chiefOnboarding.followUp.detail",
               defaultValue: "It checks on agents and builds, and tells you here when something is done or needs you.", bundle: .localizedModule)
    }

    // What Chief may do (the second step). The modes' names are Settings' own (``SettingsSchema``).
    static func modeDetail(_ mode: ChiefPermissionMode) -> String {
        switch mode {
        case .bypass:
            String(localized: "home.chiefOnboarding.mode.bypass", defaultValue: "Runs every command without asking. The default.", bundle: .localizedModule)
        case .auto:
            String(localized: "home.chiefOnboarding.mode.auto",
                   defaultValue: "A safety check approves each command and stops risky ones.", bundle: .localizedModule)
        case .manual:
            String(localized: "home.chiefOnboarding.mode.manual",
                   defaultValue: "Skips anything that needs approval and tells you instead.", bundle: .localizedModule)
        }
    }
    /// Chief's own rule (its prompt), in every mode; only Auto and Manual also check commands.
    static var toldToAsk: String {
        String(localized: "home.chiefOnboarding.toldToAsk",
               defaultValue: "Chief is told to ask before spending money, deleting data or signing in, and never to type passwords. A rule, not a lock.",
               bundle: .localizedModule)
    }
    static var changeLater: String {
        String(localized: "home.chiefOnboarding.changeLater", defaultValue: "Change it any time in Settings › Home.", bundle: .localizedModule)
    }
    static var openSettings: String { String(localized: "home.chiefOnboarding.openSettings", defaultValue: "Open Settings", bundle: .localizedModule) }
    static var managed: String {
        String(localized: "home.chiefOnboarding.managed", defaultValue: "Your organization sets this.", bundle: .localizedModule)
    }
    static var writeFailed: String {
        // retry-prompt-ok: the person's own answer, saved again only when they choose
        String(localized: "home.chiefOnboarding.writeFailed",
               defaultValue: "That didn’t save. Try again, or change it in Settings.", bundle: .localizedModule)
    }

    // How cmux looks (the last step). The densities' names are Settings' own (``SettingsSchema``).
    static var densityLabel: String { String(localized: "home.chiefOnboarding.density", defaultValue: "Density", bundle: .localizedModule) }
    static var textSizeLabel: String { String(localized: "home.chiefOnboarding.textSize", defaultValue: "Text size", bundle: .localizedModule) }
    /// The text size, a bare number in the person's locale (its label says what it is).
    static func points(_ size: Int) -> String { size.formatted() }
    static var smaller: String { String(localized: "home.chiefOnboarding.smaller", defaultValue: "Smaller text", bundle: .localizedModule) }
    static var larger: String { String(localized: "home.chiefOnboarding.larger", defaultValue: "Larger text", bundle: .localizedModule) }
    static var lookLater: String {
        String(localized: "home.chiefOnboarding.lookLater", defaultValue: "More in Settings › Appearance.", bundle: .localizedModule)
    }

    // The chat styles (``HomeChiefOnboardingCard/Style``): Chief says each step as its own message, and the
    // primary button is your reply.
    static func chatBody(_ step: ChiefOnboardingStep) -> String {
        switch step {
        case .meet:
            String(localized: "home.chiefOnboarding.chat.meet",
                   defaultValue: "Hi, I’m Chief, your assistant in cmux. Tell me what you want done, in plain words. I work only for you.",
                   bundle: .localizedModule)
        case .access:
            String(localized: "home.chiefOnboarding.chat.access",
                   defaultValue: "I run commands, edit files and use the cmux browser on this Mac, as you. How often should I check with you first?",
                   bundle: .localizedModule)
        case .look:
            String(localized: "home.chiefOnboarding.chat.look",
                   defaultValue: "Last thing: how should cmux look? Pick a density and a text size. You’ll see it change right here.",
                   bundle: .localizedModule)
        }
    }
    static func chatReply(_ step: ChiefOnboardingStep) -> String {
        switch step {
        case .meet: String(localized: "home.chiefOnboarding.chat.reply.meet", defaultValue: "Nice to meet you", bundle: .localizedModule)
        case .access: String(localized: "home.chiefOnboarding.chat.reply.access", defaultValue: "Sounds good", bundle: .localizedModule)
        case .look: String(localized: "home.chiefOnboarding.chat.reply.look", defaultValue: "Let’s go", bundle: .localizedModule)
        }
    }
}
