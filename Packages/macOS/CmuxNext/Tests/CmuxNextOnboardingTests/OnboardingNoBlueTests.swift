import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextOnboarding

/// Onboarding's primary button (Continue, Done, Import) uses the theme's
/// own foreground and background, never a blue: `Palette.highlight` is the
/// theme's ANSI blue, which is blue in most themes (lead rule: no blue).
@MainActor
@Suite struct OnboardingNoBlueTests {
    @Test func thePrimaryButtonIsNeverTheThemeBlue() {
        let button = OnboardingControl.button("Done", prominent: true, target: nil, action: #selector(NSObject.description))
        button.layoutSubtreeIfNeeded()
        let fill = button.layer?.backgroundColor
        #expect(fill != nil)
        #expect(fill != Palette.highlight.cgColor, "the primary button is the theme's ANSI blue")
        #expect(fill == Palette.textPrimary.cgColor)
    }
}
