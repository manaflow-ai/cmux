import Foundation

/// The computer use step's text.
extension OnboardingStrings {
    static var computerUseTitle: String { String(localized: "onboarding.computerUse.title", defaultValue: "Computer Use", bundle: .module) }
    static var computerUseSubtitle: String {
        String(localized: "onboarding.computerUse.subtitle",
               defaultValue: "Agents can see and use your apps when you ask them to. macOS needs two permissions for that.", bundle: .module)
    }
    static var computerUseAllow: String { String(localized: "onboarding.computerUse.allow", defaultValue: "Allow", bundle: .module) }
    /// Allow's VoiceOver label, naming the grant ("Allow Accessibility").
    static func computerUseAllowNamed(_ name: String) -> String {
        String(format: String(localized: "onboarding.computerUse.allow.named", defaultValue: "Allow %@", bundle: .module), name)
    }
    static var computerUseDone: String { String(localized: "onboarding.computerUse.done", defaultValue: "Done", bundle: .module) }
    static func computerUseName(_ pane: ComputerUsePermissionPane) -> String {
        switch pane {
        case .accessibility: String(localized: "onboarding.computerUse.accessibility", defaultValue: "Accessibility", bundle: .module)
        case .screenRecording: String(localized: "onboarding.computerUse.screenRecording", defaultValue: "Screen Recording", bundle: .module)
        }
    }
    static func computerUseDetail(_ pane: ComputerUsePermissionPane) -> String {
        switch pane {
        case .accessibility:
            String(localized: "onboarding.computerUse.accessibility.detail",
                   defaultValue: "Lets agents click, type and scroll in other apps.", bundle: .module)
        case .screenRecording:
            String(localized: "onboarding.computerUse.screenRecording.detail",
                   defaultValue: "Lets agents see the windows they work in.", bundle: .module)
        }
    }
    static var computerUseHelperDrag: String {
        String(localized: "onboarding.computerUse.helper.drag",
               defaultValue: "Drag this into the list in System Settings, then turn it on.", bundle: .module)
    }
    /// No Developer ID signed helper (a dev build): the fix is a release helper.
    static var computerUseHelperUnavailable: String {
        String(localized: "onboarding.computerUse.helper.unavailable",
               defaultValue: "Computer Use is unavailable in this dev build. Install cmux NIGHTLY to use it.", bundle: .module)
    }
    /// The helper does not speak this build's protocol.
    static var computerUseHelperVersionMismatch: String {
        String(localized: "onboarding.computerUse.helper.versionMismatch",
               defaultValue: "Computer Use helper version mismatch. Update cmux NIGHTLY and this build.", bundle: .module)
    }
    static var computerUseHelperClose: String { String(localized: "onboarding.computerUse.helper.close", defaultValue: "Close", bundle: .module) }
}
