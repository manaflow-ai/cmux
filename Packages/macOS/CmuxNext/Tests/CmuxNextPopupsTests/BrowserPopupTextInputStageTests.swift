import AppKit
@testable import CmuxNextBrowser
import CmuxNextInput
import CmuxNextInputCore
@testable import CmuxNextPopups
import Foundation
import Testing
import CmuxNextWakeups

/// A popup window's omnibar is the browser tab's (`OmnibarFieldEditor`), so its typing gets the same text input
/// stage as a main window's: the popup window carries the app's stage (`TextInputStageHosting`) and
/// the field editor stamps the key's `textInputStart` and `textInputEnd`.
@MainActor @Suite(.serialized) struct BrowserPopupTextInputStageTests {
    @Test func aKeyTypedInAPopupsOmnibarStampsItsTextInputStages() throws {
        let dispatch = InputLatencyDispatch(tracker: InputLatencyTracker(presentation: PresentationClock(), frameIntervals: nil),
                                            classifier: InputTargetClassifier(rules: []),
                                            frameInterval: { _ in 1.0 / 60 }, windowChanged: { _ in false })
        let popups = BrowserPopupWindows(mainWork: MainWorkScheduler(budget: MainFrameBudget()), inputTap: InputEventTap())
        popups.ordersWindowsIn = false
        popups.textInputStage = dispatch.textInput
        defer { popups.closeAll() }
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let opener = NSWindow(contentRect: CGRect(x: 200, y: 100, width: 1000, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: true)
        opener.isReleasedWhenClosed = false
        popups.open(tab, request: BrowserPopupRequest(size: CGSize(width: 480, height: 360)), from: opener, openerKey: "tab_opener")
        let window = try #require(popups.window(for: tab))
        #expect(window.textInputStage === dispatch.textInput, "the popup window carries the app's stage")

        #expect(window.addressBar.debugTypeAndCommit("exampl", commit: false))
        let editor = try #require(window.addressBar.fieldEditor)
        #expect(editor.window === window)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                                context: nil, characters: "e", charactersIgnoringModifiers: "e",
                                                isARepeat: false, keyCode: 14))
        let slot = try #require(dispatch.willDispatch(key, synthetic: false, keyWindow: window))
        editor.keyDown(with: key)
        dispatch.didDispatch(slot, layoutTookScroll: false)

        let table = dispatch.tracker.table
        let start = try #require(table.time(slot.token, .textInputStart), "the omnibar's input method call was not timed")
        let end = try #require(table.time(slot.token, .textInputEnd))
        let dispatchEnd = try #require(table.time(slot.token, .dispatchEnd))
        #expect(start <= end && end <= dispatchEnd)
    }
}
