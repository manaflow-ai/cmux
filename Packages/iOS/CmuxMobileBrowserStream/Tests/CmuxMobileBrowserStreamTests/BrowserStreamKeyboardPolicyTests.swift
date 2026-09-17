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

    @Test func manualHideReleasesProxyFocusWhilePageFocusRemainsEditable() {
        var policy = BrowserStreamKeyboardPolicy()
        policy.setEditableFocused(true)
        policy.noteManualHide()
        #expect(!policy.shouldFocusInput)
        // A fresh page focus edge re-raises after an explicit hide.
        policy.setEditableFocused(false)
        policy.setEditableFocused(true)
        #expect(policy.shouldFocusInput)
    }

    @Test func manualHideWithoutProxyFocusNeverRequestsFocus() {
        // The chrome button binds to REAL keyboard visibility: the keyboard can
        // be up via the address field or a dialog text field while this policy
        // holds no focus reason. Hiding then must stay a no-op, not become a
        // request the way toggling would.
        var policy = BrowserStreamKeyboardPolicy()
        policy.noteManualHide()
        #expect(!policy.shouldFocusInput)
        policy.toggleManualRequest()
        #expect(policy.shouldFocusInput)
        policy.noteManualHide()
        #expect(!policy.shouldFocusInput)
    }
}
