import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// Measurement, not a gate (#32909 step B, lead 2026-11-03: the Ctrl-Tab restore is work on a visible action):
/// the cost of one tab switch in a pane's shared chrome, two tabs each wired like the App wires a tab (toolbar
/// sources, badge, star, history). Prints `CHROME-SWITCH p50_us=… p95_us=… max_us=… sources_per_switch=… renders_per_switch=…`.
/// The regression test beside it: a switch renders the toolbar once, not once per toolbar source it sets.
@MainActor @Suite(.serialized, .closesItsWindows) struct BrowserChromeSwitchBench {
    final class Counter { var configures = 0 }

    static func wired(_ host: String, _ counter: Counter, downloading: Bool = false) -> BrowserEntry {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://\(host)/")))
        tab.load(URL(string: "https://\(host)/")!)
        let entry = BrowserEntry(tab: tab, history: InMemoryBrowserHistory())
        entry.state.profileBadge = BrowserProfileBadge(monogram: "W", color: nil, name: "Work")
        entry.state.bookmarkStar = .off
        entry.state.configureToolbar = { buttons in
            counter.configures += 1
            buttons.shortcutHint = { _ in "⌘K" }
            buttons.downloads = { downloading ? BrowserToolbarDownloads(count: 1, inProgress: true, progress: 0.5) : BrowserToolbarDownloads() }
            buttons.media = { BrowserToolbarMedia() }
            buttons.pins = { [] }
        }
        return entry
    }

    @Test func aSwitchRendersTheToolbarOnce() {
        let counter = Counter()
        // Each tab has its own downloads (a names a running download): the one render shows the shown tab's.
        let a = Self.wired("a.example", counter, downloading: true), b = Self.wired("b.example", counter)
        let pane = BrowserPaneChrome()
        defer {
            pane.drop()
            a.close()
            b.close()
        }
        let buttons = pane.bind(a.tab, state: a.state).toolbarButtons
        pane.bind(b.tab, state: b.state)
        let before = buttons.renders
        for _ in 0..<10 {
            pane.bind(a.tab, state: a.state)
            #expect(buttons.state(.downloads)?.progress != nil, "tab a's running download shows after the switch to it")
            pane.bind(b.tab, state: b.state)
            #expect(buttons.state(.downloads)?.progress == nil, "tab b shows no download after the switch to it")
        }
        let perSwitch = Double(buttons.renders - before) / 20
        #expect(perSwitch == 1, "a tab switch rendered the toolbar \(perSwitch) times (one per source it set, or none)")
    }

    @Test func switchCost() {
        let counter = Counter()
        let a = Self.wired("a.example", counter), b = Self.wired("b.example", counter)
        let pane = BrowserPaneChrome()
        let chrome = pane.bind(a.tab, state: a.state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        chrome.frame = window.contentLayoutRect
        window.contentView = chrome
        defer {
            window.close()
            pane.drop()
            a.close()
            b.close()
        }
        pane.bind(b.tab, state: b.state)
        chrome.layoutSubtreeIfNeeded()
        let before = counter.configures, renders = chrome.toolbarButtons.renders
        var samples: [Double] = []
        for i in 0..<200 {
            let next = i % 2 == 0 ? a : b
            let start = DispatchTime.now().uptimeNanoseconds
            pane.bind(next.tab, state: next.state)
            chrome.layoutSubtreeIfNeeded()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
        }
        samples.sort()
        let pick = { (p: Double) in samples[min(samples.count - 1, Int((p * Double(samples.count - 1)).rounded()))] }
        let sources = Double(counter.configures - before) / Double(samples.count)
        print("CHROME-SWITCH p50_us=\(Int(pick(0.5))) p95_us=\(Int(pick(0.95))) max_us=\(Int(samples.last ?? 0)) sources_per_switch=\(sources) renders_per_switch=\(Double(chrome.toolbarButtons.renders - renders) / Double(samples.count))")
        #expect(!samples.isEmpty)
    }
}
