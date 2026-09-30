import AppKit
import Testing
@testable import CmuxNextBrowser

/// Late completions and second owners of a Chromium page's visibility
/// (plans/cmux-next/tab-lifecycle.md), without starting CEF.
@MainActor
@Suite struct CEFLifecycleRaceTests {
    private final class Recorder: BrowserTabDelegate {
        var intents: [String] = []
        func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
            intents.append(String(describing: intent))
        }
    }

    private func makeTab(pane: String = UUID().uuidString) -> CEFTab {
        let runtime = CEFRuntime.shared
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: pane), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        return tab
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Chromium echoes the activation of a tab it created or that cmux
    /// activated. The echo can land after the user selected another tab;
    /// it must not select this one again (the selection jumped back).
    @Test func aLateActivationEchoDoesNotSelectATabTheUserLeft() async {
        let tab = makeTab()
        let recorder = Recorder()
        tab.delegate = recorder
        CEFRuntime.shared.register(tab, browser: 70_001)
        defer { CEFRuntime.shared.tabsByBrowser[70_001] = nil }
        // The tab is not shown (its content view is in no window).
        CEFRuntime.shared.handle(.tab(.activated, browser: 70_001, window: 9, value: 0))
        for _ in 0..<10 { await Task.yield() }
        #expect(recorder.intents.isEmpty)
    }

    /// The content lifecycle hid the page; its content view entering a
    /// window again (a pane re-installing the same view) must not show it.
    /// Visibility has one owner.
    @Test func enteringAWindowDoesNotShowAPageTheLifecycleHid() async {
        let tab = makeTab()
        let window = makeWindow()
        window.contentView?.addSubview(tab.contentView)
        #expect(tab.host.visibleTab === tab)
        await tab.setOccluded(true)
        #expect(tab.host.hostView.isHidden)
        tab.contentView.removeFromSuperview()
        window.contentView?.addSubview(tab.contentView)
        #expect(tab.host.hostView.isHidden)
    }
}
