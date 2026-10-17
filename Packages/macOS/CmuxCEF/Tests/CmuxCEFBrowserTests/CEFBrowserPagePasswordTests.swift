import CmuxBrowser
import CmuxCEF
import Foundation
import Testing
@testable import CmuxCEFBrowser

/// Chromium's password save answers and agent-driven reopening (cmux Next
/// `CEFPasswordPrompts`, `AppBrowserPage+AgentDriven`).
@Suite
struct CEFBrowserPagePasswordTests {
    @Test func saveBecomesUpdateAndAnUpdateHasNoNever() {
        #expect(CEFBrowserPage.action(for: .save, isUpdate: false) == .save)
        #expect(CEFBrowserPage.action(for: .save, isUpdate: true) == .update)
        #expect(CEFBrowserPage.action(for: .never, isUpdate: false) == .never)
        #expect(CEFBrowserPage.action(for: .never, isUpdate: true) == .dismiss)
        #expect(CEFBrowserPage.action(for: .notNow, isUpdate: false) == .dismiss)
        #expect(CEFBrowserPage.action(for: nil, isUpdate: false) == .dismiss)
    }

    @Test func onlyALoadedDocumentCanHoldAFilledPassword() {
        #expect(CEFBrowserPage.holdsDocument(URL(string: "https://example.com/login")))
        #expect(CEFBrowserPage.holdsDocument(URL(string: "http://localhost:19250/")))
        #expect(!CEFBrowserPage.holdsDocument(URL(string: "about:blank")))
        #expect(!CEFBrowserPage.holdsDocument(nil))
    }
}
