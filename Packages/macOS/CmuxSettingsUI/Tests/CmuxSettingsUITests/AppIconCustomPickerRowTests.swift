import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite struct AppIconCustomPickerRowTests {
    @Test func displayNameTrimsPersistedPathWhitespace() {
        #expect(
            AppIconCustomPickerRow.displayName(for: "  /tmp/Private Icon.png  ")
                == "Private Icon.png"
        )
    }

    @Test func invalidCustomImageKeepsBuiltInModeSelected() {
        #expect(!AppSection.customImageIsActive(path: "/tmp/missing-icon.png", isValid: false))
        #expect(!AppSection.customImageIsActive(path: "   ", isValid: true))
        #expect(AppSection.customImageIsActive(path: "/tmp/icon.png", isValid: true))
    }
}
