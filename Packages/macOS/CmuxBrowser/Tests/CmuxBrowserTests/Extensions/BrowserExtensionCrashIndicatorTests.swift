import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser extension crash indicator")
struct BrowserExtensionCrashIndicatorTests {
    private let blocker = BrowserExtensionInfo(id: "blocker", name: "Blocker", isTerminated: true, hasAction: true, isPinned: true)
    private let notes = BrowserExtensionInfo(id: "notes", name: "Notes", isTerminated: true)
    private let healthy = BrowserExtensionInfo(id: "healthy", name: "Healthy")

    @Test("hidden while nothing crashed")
    func hiddenWithoutCrashes() {
        let indicator = BrowserExtensionCrashIndicator(extensions: [healthy], visibleActionIDs: [])
        #expect(!indicator.isShown)
        #expect(indicator.extensionIDs.isEmpty)
    }

    @Test("a crashed extension without a visible button shows the indicator")
    func crashedWithoutButton() {
        let indicator = BrowserExtensionCrashIndicator(extensions: [healthy, notes], visibleActionIDs: [])
        #expect(indicator.isShown)
        #expect(indicator.extensionIDs == ["notes"])
        #expect(indicator.names == ["Notes"])
    }

    @Test("a crashed pinned button already shows its own warning")
    func crashedVisibleButton() {
        let indicator = BrowserExtensionCrashIndicator(extensions: [blocker], visibleActionIDs: ["blocker"])
        #expect(!indicator.isShown)
    }

    @Test("an overflowed crashed pin still needs the indicator")
    func crashedOverflowedPin() {
        let indicator = BrowserExtensionCrashIndicator(extensions: [blocker, notes], visibleActionIDs: ["other"])
        #expect(indicator.extensionIDs == ["blocker", "notes"])
    }
}
