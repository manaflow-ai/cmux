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
}
