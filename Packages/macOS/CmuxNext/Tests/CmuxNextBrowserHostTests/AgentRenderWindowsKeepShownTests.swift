import AppKit
@testable import CmuxNextBrowserHost
import CmuxNextWakeups
import Testing

/// A tab parked in an agent's render window is told to keep its page shown while it is parked
/// (`WebKitTab.setKeptRendering`, which shows a page the `webkitHiddenTabs` feature hid), and told so no longer
/// when the park ends.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct AgentRenderWindowsKeepShownTests {
    @MainActor final class Told {
        var values: [Bool] = []
    }

    @Test func aParkedChromeKeepsItsPageShownUntilItsRenderWindowGoes() {
        _ = NSApplication.shared
        let windows = AgentRenderWindows(mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let chrome = NSView()
        let told = Told()
        let tell: @MainActor (Bool) -> Void = { told.values.append($0) }
        let parked = windows.keepRendering(tabID: "tab", chrome: chrome, webView: nil, keepsPageShown: tell)
        #expect(parked)
        #expect(told.values == [true], "the parked page was not kept shown")
        #expect(chrome.window != nil, "the chrome did not move into the render window")
        windows.release(tabID: "tab")
        #expect(told.values == [true, false], "the page stayed kept shown after its render window went")
        windows.release(tabID: "tab")
        #expect(told.values == [true, false], "a second release told the page again")
    }

    @Test func aNewParkEndsTheOldOneFirst() {
        _ = NSApplication.shared
        let windows = AgentRenderWindows(mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let chrome = NSView()
        let told = Told()
        let tell: @MainActor (Bool) -> Void = { told.values.append($0) }
        let parked = windows.keepRendering(tabID: "tab", chrome: chrome, webView: nil, keepsPageShown: tell)
        #expect(parked)
        // A pane parked it hidden, so it is a background tab again and the next driver call parks it anew.
        chrome.isHidden = true
        let parkedAgain = windows.keepRendering(tabID: "tab", chrome: chrome, webView: nil, keepsPageShown: tell)
        #expect(parkedAgain)
        #expect(told.values == [true, false, true], "the new park did not end the old one before it began")
        windows.release(tabID: "tab")
        #expect(told.values.last == false)
    }
}
