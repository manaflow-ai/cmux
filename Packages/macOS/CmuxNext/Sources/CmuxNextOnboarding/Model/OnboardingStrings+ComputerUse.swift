import Foundation

/// The Computer Use setup window's text.
extension OnboardingStrings {
    /// The window's title in the Window menu and for VoiceOver.
    static var computerUseTitle: String { String(localized: "onboarding.computerUse.title", defaultValue: "Computer Use", bundle: .l10n) }
    static var computerUseHeading: String {
        String(localized: "onboarding.computerUse.heading", defaultValue: "Turn On Computer Use", bundle: .l10n)
    }
    static var computerUseBody: String {
        String(localized: "onboarding.computerUse.body", defaultValue: "Agents can use your apps when you ask them to.", bundle: .l10n)
    }
    /// The body once every grant is on.
    static var computerUseReady: String {
        String(localized: "onboarding.computerUse.ready", defaultValue: "Computer Use is ready.", bundle: .l10n)
    }
    static var computerUseAllow: String { String(localized: "onboarding.computerUse.allow", defaultValue: "Allow", bundle: .l10n) }
    /// Allow's VoiceOver label, naming the grant ("Allow Accessibility").
    static func computerUseAllowNamed(_ name: String) -> String {
        String(format: String(localized: "onboarding.computerUse.allow.named", defaultValue: "Allow %@", bundle: .l10n), name)
    }
    static var computerUseDone: String { String(localized: "onboarding.computerUse.done", defaultValue: "Done", bundle: .l10n) }
    static var computerUseNotNow: String { String(localized: "onboarding.computerUse.notNow", defaultValue: "Not Now", bundle: .l10n) }
    static func computerUseName(_ pane: ComputerUsePermissionPane) -> String {
        switch pane {
        case .accessibility: String(localized: "onboarding.computerUse.accessibility", defaultValue: "Accessibility", bundle: .l10n)
        case .screenRecording: String(localized: "onboarding.computerUse.screenshots", defaultValue: "Screenshots", bundle: .l10n)
        }
    }
    static func computerUseLine(_ pane: ComputerUsePermissionPane) -> String {
        switch pane {
        case .accessibility:
            String(localized: "onboarding.computerUse.accessibility.line",
                   defaultValue: "Lets agents click and type in your apps", bundle: .l10n)
        case .screenRecording:
            String(localized: "onboarding.computerUse.screenshots.line",
                   defaultValue: "Lets agents see the window they work in", bundle: .l10n)
        }
    }
    /// The drag panel's line: the helper's name, then the grant's (both shown bold).
    static func computerUseDragLine(helper: String, grant: String) -> String {
        String(format: String(localized: "onboarding.computerUse.panel.drag",
                              defaultValue: "Drag %1$@ to the list above to allow %2$@", bundle: .l10n), helper, grant)
    }
    /// No Developer ID signed helper (a dev build): the fix is a release helper.
    static var computerUseHelperUnavailable: String {
        String(localized: "onboarding.computerUse.helper.unavailable",
               defaultValue: "Computer Use is unavailable in this dev build. Install cmux NIGHTLY to use it.", bundle: .l10n)
    }
    /// Computer Use is off, so its grants are unknown until Allow turns it on.
    static var computerUseOff: String {
        String(localized: "onboarding.computerUse.off",
               defaultValue: "Computer Use is off. Allow turns it on, then shows its permissions here.", bundle: .l10n)
    }
    /// The helper does not speak this build's protocol.
    static var computerUseHelperVersionMismatch: String {
        String(localized: "onboarding.computerUse.helper.versionMismatch",
               defaultValue: "Computer Use helper version mismatch. Update cmux NIGHTLY and this build.", bundle: .l10n)
    }
    static var computerUseHelperFailed: String {
        String(localized: "onboarding.computerUse.helper.failed",
               defaultValue: "The cmux Computer Use helper did not respond. Restart the helper to try again.", bundle: .l10n)
    }
    static var computerUseRestart: String {
        String(localized: "onboarding.computerUse.restart", defaultValue: "Restart", bundle: .l10n)
    }
}
