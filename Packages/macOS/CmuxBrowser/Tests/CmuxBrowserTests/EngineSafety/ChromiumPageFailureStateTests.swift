import CmuxBrowser
import Darwin
import Foundation
import Testing

@Suite struct ChromiumPageFailureStateTests {
    let start = Date(timeIntervalSince1970: 1_000)
    let crash = BrowserPageEvent.processTerminated(BrowserPageProcessExit(kind: .crashed, status: SIGSEGV))

    @Test func visibleCrashShowsAwSnapAndWaitsForReload() {
        var state = ChromiumPageFailureState()
        state.apply(crash, at: start, paneVisible: true)
        #expect(state.failure == .crashed(
            ChromiumCrashPageVariant(isRepeat: false, isOutOfMemory: false, errorCode: "SIGSEGV"),
            restoresWhenShown: false
        ))
        #expect(state.showsPrompt)
        // Hiding and showing the pane does not reload a page that crashed in view.
        #expect(!state.paneShown())
        #expect(state.showsPrompt)
        state.userReloaded()
        #expect(state.failure == nil)
    }

    @Test func hiddenCrashRestoresWhenShownWithinBudget() {
        var state = ChromiumPageFailureState()
        for index in 0..<BrowserCrashReloadGuard.limit {
            state.apply(crash, at: start.addingTimeInterval(Double(index) * 60), paneVisible: false)
            #expect(!state.showsPrompt)
            #expect(state.paneShown())
            #expect(state.failure == nil)
        }
        // Budget spent: the next hidden crash shows the crash page when shown.
        state.apply(crash, at: start.addingTimeInterval(300), paneVisible: false)
        #expect(!state.paneShown())
        #expect(state.showsPrompt)
    }

    @Test func repeatCrashWithinTenSecondsSaysCantOpen() {
        var state = ChromiumPageFailureState()
        state.apply(crash, at: start, paneVisible: true)
        state.userReloaded()
        state.apply(.processTerminated(.init(kind: .outOfMemory)), at: start.addingTimeInterval(4), paneVisible: true)
        guard case .crashed(let variant, _) = state.failure else {
            Issue.record("expected a crash page")
            return
        }
        #expect(variant.isRepeat)
        #expect(variant.isOutOfMemory)
    }

    @Test func committedNavigationClearsTheFailure() {
        var state = ChromiumPageFailureState()
        state.apply(crash, at: start, paneVisible: true)
        state.apply(.navigationCommitted(URL(string: "https://example.com")), at: start, paneVisible: true)
        #expect(state.failure == nil)
    }

    @Test func hangPromptWaitAndExit() {
        var state = ChromiumPageFailureState()
        state.apply(.unresponsiveChanged(true), at: start, paneVisible: true)
        #expect(state.failure == .unresponsive)
        state.answeredUnresponsive(terminate: false)
        #expect(state.failure == nil)

        state.apply(.unresponsiveChanged(true), at: start, paneVisible: true)
        state.answeredUnresponsive(terminate: true)
        #expect(state.failure == .unresponsive)
        state.apply(.processTerminated(.init(kind: .killed, status: SIGKILL)), at: start, paneVisible: true)
        guard case .crashed(let variant, false) = state.failure else {
            Issue.record("expected a crash page after Exit page")
            return
        }
        #expect(variant.errorCode == "SIGKILL")
    }

    @Test func pageRecoveringClearsTheHangOnly() {
        var state = ChromiumPageFailureState()
        state.apply(.unresponsiveChanged(true), at: start, paneVisible: true)
        state.apply(.unresponsiveChanged(false), at: start, paneVisible: true)
        #expect(state.failure == nil)
        // A late "responsive" never hides a crash page.
        state.apply(crash, at: start, paneVisible: true)
        state.apply(.unresponsiveChanged(false), at: start, paneVisible: true)
        #expect(state.showsPrompt)
        // A hang report while crashed does not replace the crash page.
        state.apply(.unresponsiveChanged(true), at: start, paneVisible: true)
        if case .crashed = state.failure {} else { Issue.record("crash page replaced") }
    }
}
