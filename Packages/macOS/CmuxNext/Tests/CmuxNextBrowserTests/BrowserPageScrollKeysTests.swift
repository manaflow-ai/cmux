import AppKit
@testable import CmuxNextBrowser
import Testing

/// The app's side of a held `j` (``BrowserPageScrollKeys``): a scroll whose key is held runs
/// until that key's key-up, which the app sends the page too (the page may have missed it); a
/// scroll with no key held (the palette, a tap already over) is one step.
@MainActor
struct BrowserPageScrollKeysTests {
    private static let j: UInt16 = 38

    /// A key event stamped `stamp` (event clock): far from the uptime clock, as on a Mac that slept.
    private static func key(_ type: NSEvent.EventType, stamp: TimeInterval = 12_000) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: stamp, windowNumber: 0, context: nil,
                         characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: j)!
    }

    private static func evaluations(of tab: MockBrowserTab, count: Int) async -> [String] {
        for _ in 0..<200 {
            let scripts = tab.commands.compactMap { if case .evaluate(let script) = $0 { script } else { nil } }
            if scripts.count >= count { return scripts }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return tab.commands.compactMap { if case .evaluate(let script) = $0 { script } else { nil } }
    }

    @Test func noKeyHeldIsOneStep() async {
        let keys = BrowserPageScrollKeys(watching: false)
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(initialURL: nil))
        keys.run(.down, on: tab)
        #expect(await Self.evaluations(of: tab, count: 2) == [BrowserPageScroll.down.script, BrowserPageScroll.release("j")])
    }

    @Test func aHeldKeyRunsUntilItsKeyUp() async {
        let keys = BrowserPageScrollKeys(watching: false)
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(initialURL: nil))
        keys.observe(Self.key(.keyDown))
        keys.run(.down, on: tab)
        let held = BrowserPageScroll.down.script(topSpeed: BrowserPageScroll.topSpeed(keyRepeatInterval: NSEvent.keyRepeatInterval))
        #expect(await Self.evaluations(of: tab, count: 1) == [held])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await Self.evaluations(of: tab, count: 1).count == 1, "no release while the key is down")
        keys.observe(Self.key(.keyUp))
        #expect(await Self.evaluations(of: tab, count: 2).last == BrowserPageScroll.release("j"))
    }

    /// A key whose key-up went to another app is not held seconds later.
    @Test func aStaleKeyDownIsNotHeld() async {
        let keys = BrowserPageScrollKeys(watching: false)
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(initialURL: nil))
        keys.observe(Self.key(.keyDown), at: ProcessInfo.processInfo.systemUptime - 5)
        keys.run(.down, on: tab)
        #expect(await Self.evaluations(of: tab, count: 2).last == BrowserPageScroll.release("j"))
    }
}
