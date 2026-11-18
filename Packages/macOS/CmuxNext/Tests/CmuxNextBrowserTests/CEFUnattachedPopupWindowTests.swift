import AppKit
@testable import CmuxNextBrowser
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// An extension's popup window (`chrome.windows.create({type: "popup"})`) stays hidden in Chromium
/// until a cmux panel attaches it (Fable's passkey review D2, 2026-11-17). When no panel ever shows
/// it (no handler took the opener's `.openPopup`, or the panel never reached a window), the window
/// stayed hidden for good: the extension waited for a `windows.onRemoved` that never came (Bitwarden's
/// passkey popout then never falls back to the browser's own passkey). Chrome shows every such window,
/// and closing it is the person's way out. A popup window that is not attached within
/// `CEFPopupWindows.attachLimit` now closes; one that attached stays.
extension CEFSparePageSuites {
    @MainActor @Suite struct CEFUnattachedPopupWindowTests {
        typealias Fixture = CEFSparePageSuites.CEFSparePageTests

        @Test func aPopupWindowNoPanelShowsClosesSoTheExtensionSeesItRemoved() async throws {
            let clock = ManualClock()
            let (runtime, root) = try Fixture.runtime(clock: clock)
            defer { Fixture.tearDown(runtime, root) }
            let (host, opener, _) = try Fixture.liveHost(runtime)
            SpareSpy.clearRecords()

            // Nobody handles the opener's `.openPopup`: no panel shows the window.
            host.adoptPopupWindow(window: 7, browser: 40, bounds: nil, opener: opener)
            #expect(SpareSpy.closed.isEmpty)

            try await clock.waitForSleeper()
            clock.advance(by: .seconds(30))
            for _ in 0..<20 where !SpareSpy.closed.contains(40) { await Task.yield() }
            #expect(SpareSpy.closed.contains(40), "the hidden window's tab closes: chrome.windows.onRemoved")
            #expect(!SpareSpy.closed.contains(10), "the opener stays")
        }

        @Test func anAttachedPopupWindowStays() async throws {
            let clock = ManualClock()
            let (runtime, root) = try Fixture.runtime(clock: clock)
            defer { Fixture.tearDown(runtime, root) }
            let (host, opener, _) = try Fixture.liveHost(runtime)
            SpareSpy.clearRecords()

            host.adoptPopupWindow(window: 7, browser: 40, bounds: nil, opener: opener)
            let popupHost = try #require(runtime.hosts.values.first { $0.popupWindow == 7 })
            let popup = try #require(runtime.tabsByBrowser[40])
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView?.addSubview(popupHost.hostView)
            #expect(popupHost.attachPopupWindowIfNeeded(popup))
            #expect(popupHost.window == .live(window: 7))

            clock.advance(by: .seconds(30))
            for _ in 0..<20 { await Task.yield() }
            #expect(!SpareSpy.closed.contains(40), "a shown popup closes only when the person or the extension closes it")
        }
    }
}
