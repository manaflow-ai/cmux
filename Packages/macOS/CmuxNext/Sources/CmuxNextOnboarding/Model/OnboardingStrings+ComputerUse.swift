import Foundation

/// The Computer Use setup window's text.
extension OnboardingStrings {
    /// The window's title in the Window menu and for VoiceOver.
    static var computerUseTitle: String { String(localized: "onboarding.computerUse.title", defaultValue: "Computer Use", bundle: .localizedModule) }
    /// The body once every grant is on.
    static var computerUseReady: String {
        String(localized: "onboarding.computerUse.ready", defaultValue: "Computer Use is ready.", bundle: .localizedModule)
    }
    static func computerUseName(_ pane: ComputerUsePermissionPane) -> String {
        switch pane {
        case .accessibility: String(localized: "onboarding.computerUse.accessibility", defaultValue: "Accessibility", bundle: .localizedModule)
        case .screenRecording: String(localized: "onboarding.computerUse.screenshots", defaultValue: "Screenshots", bundle: .localizedModule)
        }
    }
    static func computerUseLine(_ pane: ComputerUsePermissionPane) -> String {
        switch pane {
        case .accessibility:
            String(localized: "onboarding.computerUse.accessibility.line",
                   defaultValue: "Lets agents click and type in your apps", bundle: .localizedModule)
        case .screenRecording:
            String(localized: "onboarding.computerUse.screenshots.line",
                   defaultValue: "Lets agents see the window they work in", bundle: .localizedModule)
        }
    }
    /// The drag panel's line: the helper's name, then the grant's (both shown bold).
    static func computerUseDragLine(helper: String, grant: String) -> String {
        String(format: String(localized: "onboarding.computerUse.panel.drag",
                              defaultValue: "Drag %1$@ to the list above to allow %2$@", bundle: .localizedModule), helper, grant)
    }
    /// The drag panel's second line: a dropped helper lands switched off in the list.
    static var computerUseTurnOn: String {
        String(localized: "onboarding.computerUse.panel.turnOn", defaultValue: "Then turn it on.", bundle: .localizedModule)
    }
}
