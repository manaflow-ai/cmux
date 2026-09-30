import Foundation

/// Default browser, default terminal and tour text.
extension OnboardingStrings {
    static var browserTitle: String { String(localized: "onboarding.browser.title", defaultValue: "Make cmux Your Browser", bundle: .module) }
    static var browserSubtitle: String {
        String(localized: "onboarding.browser.subtitle", defaultValue: "Links from any app open as tabs in your current cmux window, next to your terminals.", bundle: .module)
    }
    static func currentBrowser(_ name: String) -> String {
        String(format: String(localized: "onboarding.browser.current", defaultValue: "Current default: %@", bundle: .module), name)
    }
    static var isDefaultBrowser: String { String(localized: "onboarding.browser.isDefault", defaultValue: "cmux is your default browser.", bundle: .module) }
    static var makeDefaultBrowser: String { String(localized: "onboarding.browser.make", defaultValue: "Make Default Browser", bundle: .module) }
    static var confirmHint: String { String(localized: "onboarding.browser.confirmHint", defaultValue: "macOS asks you to confirm.", bundle: .module) }
    static var waiting: String { String(localized: "onboarding.browser.waiting", defaultValue: "Waiting for macOS…", bundle: .module) }
    static func systemRefused(_ reason: String) -> String {
        String(format: String(localized: "onboarding.system.refused", defaultValue: "macOS did not make the change: %@", bundle: .module), reason)
    }

    static var terminalTitle: String { String(localized: "onboarding.terminal.title", defaultValue: "Make cmux Your Terminal", bundle: .module) }
    static var terminalSubtitle: String {
        String(localized: "onboarding.terminal.subtitle", defaultValue: "macOS has no default terminal setting. cmux can take over what opens Terminal.", bundle: .module)
    }
    static var useAll: String { String(localized: "onboarding.terminal.useAll", defaultValue: "Use cmux for All", bundle: .module) }
    static var use: String { String(localized: "onboarding.terminal.use", defaultValue: "Use cmux", bundle: .module) }
    static var inUse: String { String(localized: "onboarding.terminal.inUse", defaultValue: "In Use", bundle: .module) }
    static var openSettings: String { String(localized: "onboarding.terminal.openSettings", defaultValue: "Open Settings", bundle: .module) }
    static var terminalLimits: String {
        String(localized: "onboarding.terminal.limits", defaultValue: "Apps that start Terminal directly, such as an editor's Open in Terminal command, still do. Choose cmux in their own settings.", bundle: .module)
    }

    static func claimTitle(_ claim: DefaultHandlerClaim) -> String {
        switch claim {
        case .webBrowser: String(localized: "onboarding.claim.webBrowser.title", defaultValue: "Web links", bundle: .module)
        case .ssh: String(localized: "onboarding.claim.ssh.title", defaultValue: "SSH links", bundle: .module)
        case .manPage: String(localized: "onboarding.claim.manPage.title", defaultValue: "Manual pages", bundle: .module)
        case .shellScripts: String(localized: "onboarding.claim.shellScripts.title", defaultValue: "Shell scripts", bundle: .module)
        }
    }

    static func claimDetail(_ claim: DefaultHandlerClaim) -> String {
        switch claim {
        case .webBrowser: String(localized: "onboarding.claim.webBrowser.detail", defaultValue: "http and https links open in cmux.", bundle: .module)
        case .ssh: String(localized: "onboarding.claim.ssh.detail", defaultValue: "ssh:// links open a new tab and connect.", bundle: .module)
        case .manPage: String(localized: "onboarding.claim.manPage.detail", defaultValue: "x-man-page:// links open man in a new tab.", bundle: .module)
        case .shellScripts: String(localized: "onboarding.claim.shellScripts.detail", defaultValue: ".command, .sh, .zsh and .tool files run in a new tab.", bundle: .module)
        }
    }

    static var serviceTitle: String { String(localized: "onboarding.claim.service.title", defaultValue: "New cmux Tab Here", bundle: .module) }
    static var serviceDetail: String {
        String(localized: "onboarding.claim.service.detail", defaultValue: "A Finder service for folders. Turn it on in Keyboard Shortcuts, Services.", bundle: .module)
    }

    static var tourTitle: String { String(localized: "onboarding.tour.title", defaultValue: "Key Ideas", bundle: .module) }
    static var tourSubtitle: String { String(localized: "onboarding.tour.subtitle", defaultValue: "Five things that make cmux fast.", bundle: .module) }

    static func tourTitle(_ kind: TourPage.Kind) -> String {
        switch kind {
        case .palette: String(localized: "onboarding.tour.palette.title", defaultValue: "Everything is in the palette", bundle: .module)
        case .keyTiers: String(localized: "onboarding.tour.keyTiers.title", defaultValue: "Some keys always reach cmux", bundle: .module)
        case .rooms: String(localized: "onboarding.tour.rooms.title", defaultValue: "Rooms", bundle: .module)
        case .splits: String(localized: "onboarding.tour.splits.title", defaultValue: "Splits and columns", bundle: .module)
        case .screens: String(localized: "onboarding.tour.screens.title", defaultValue: "Screens, when you want them", bundle: .module)
        }
    }

    static func tourBody(_ kind: TourPage.Kind) -> String {
        switch kind {
        case .palette:
            String(localized: "onboarding.tour.palette.body", defaultValue: "Every action, setting and tab is one search away.", bundle: .module)
        case .keyTiers:
            String(localized: "onboarding.tour.keyTiers.body", defaultValue: "Focus and window keys work even inside a web page or a full-screen terminal app. Other keys go to what you type in.", bundle: .module)
        case .rooms:
            String(localized: "onboarding.tour.rooms.body", defaultValue: "Switch between sets of workspaces, each with its own theme. The dots at the bottom of the sidebar are your rooms.", bundle: .module)
        case .splits:
            String(localized: "onboarding.tour.splits.body", defaultValue: "Split any pane, or scroll through columns sideways. Drag a tab anywhere to move it.", bundle: .module)
        case .screens:
            String(localized: "onboarding.tour.screens.body", defaultValue: "Keep several full layouts in one workspace, like tmux windows. They stay hidden until you show the switcher.", bundle: .module)
        }
    }
}
