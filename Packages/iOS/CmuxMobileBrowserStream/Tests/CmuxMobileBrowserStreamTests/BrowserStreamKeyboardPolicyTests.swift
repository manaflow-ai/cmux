import Testing
@testable import CmuxMobileBrowserStream

@Suite struct BrowserStreamKeyboardPolicyTests {
    @Test func pageEditableFocusDrivesKeyboard() {
        var policy = BrowserStreamKeyboardPolicy()
        #expect(!policy.shouldFocusInput)
        policy.setEditableFocused(true)
        #expect(policy.shouldFocusInput)
        policy.setEditableFocused(false)
        #expect(!policy.shouldFocusInput)
    }

    @Test func manualRequestSurvivesMissingPageFocusUntilToggledOrDismissed() {
        var policy = BrowserStreamKeyboardPolicy()
        policy.toggleManualRequest()
        #expect(policy.shouldFocusInput)
        policy.setEditableFocused(false)
        #expect(policy.shouldFocusInput)
        policy.toggleManualRequest()
        #expect(!policy.shouldFocusInput)
        policy.toggleManualRequest()
        policy.dismiss()
        #expect(!policy.shouldFocusInput)
    }

    @Test func manualToggleCanHideKeyboardWhilePageFocusRemainsEditable() {
        var policy = BrowserStreamKeyboardPolicy()
        policy.setEditableFocused(true)
        policy.toggleManualRequest()
        #expect(!policy.shouldFocusInput)
        policy.setEditableFocused(true)
        #expect(!policy.shouldFocusInput)
        policy.setEditableFocused(false)
        policy.setEditableFocused(true)
        #expect(policy.shouldFocusInput)
    }
}
