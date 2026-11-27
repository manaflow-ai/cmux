import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Extension popup windows (user 2026-11-17, Bitwarden's passkey popout): `chrome.windows.create({type:
/// "popup"})` has no opener, so cmux shows the window over the last shown pane. That pane was often a
/// cmux page (Home, an agent chat, New Tab) in Chromium: such a page lets no popup open (it closes the
/// tab and asks to open its URL as a link), so the extension's window closed within 100 ms and the
/// extension got `windows.onRemoved` at once (live on cmux-lawrence-2). The window now opens over the
/// last shown web pane of a regular profile that is in a window, and over no pane when none shows.
extension CEFSparePageSuites {
    @MainActor @Suite struct CEFPopupWindowOpenerTests {
        typealias Fixture = CEFSparePageSuites.CEFSparePageTests

        /// A window off screen, closed by the test.
        private static func window() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }

        /// A pane of `runtime` showing a tab (not created yet) in a view of its own.
        private static func shown(_ runtime: CEFRuntime, profile: BrowserProfileID, offTheRecord: Bool) -> (CEFTab, NSView) {
            let key = CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: profile, offTheRecord: offTheRecord)
            let host = runtime.host(for: key)
            host.endOfTurn = { $0() }
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let tab = CEFTab(id: .random(), profile: profile, host: host, runtime: runtime)
            host.add(tab)
            host.present(tab, in: container)
            return (tab, container)
        }

        @Test func anExtensionPopupWindowOpensOverTheLastWebPaneNotOverACmuxPage() throws {
            let (runtime, root) = try Fixture.runtime()
            defer { Fixture.tearDown(runtime, root) }
            Fixture.setSparePage(false)
            let (web, webView) = Self.shown(runtime, profile: .default, offTheRecord: false)
            // A cmux page shows after it: the cmux pages' store is off the record.
            let (page, pageView) = Self.shown(runtime, profile: BrowserProfileID(rawValue: UUID()), offTheRecord: true)
            _ = (webView, pageView)
            #expect(runtime.lastShownHost === page.host)
            #expect(runtime.popupWindowOpener() === web, "the extension's window opened over a cmux page, which closes it at once")
        }

        /// A pane in no window defers the attach with no limit (the window stays hidden): a web pane in a
        /// window wins over a later shown one that is in none.
        @Test func aWebPaneInAWindowWinsOverALaterOneInNoWindow() throws {
            let (runtime, root) = try Fixture.runtime()
            defer { Fixture.tearDown(runtime, root) }
            Fixture.setSparePage(false)
            let window = Self.window()
            defer { window.close() }
            let (inWindow, inWindowView) = Self.shown(runtime, profile: .default, offTheRecord: false)
            window.contentView?.addSubview(inWindowView)
            let (_, parkedView) = Self.shown(runtime, profile: .default, offTheRecord: false)
            _ = parkedView
            #expect(inWindow.host.hostView.window === window)
            #expect(runtime.popupWindowOpener() === inWindow, "the extension's window waited on a pane in no window")
        }

        @Test func withOnlyCmuxPagesShownNoPaneTakesTheWindow() throws {
            let (runtime, root) = try Fixture.runtime()
            defer { Fixture.tearDown(runtime, root) }
            Fixture.setSparePage(false)
            let (page, pageView) = Self.shown(runtime, profile: BrowserProfileID(rawValue: UUID()), offTheRecord: true)
            _ = pageView
            #expect(runtime.lastShownHost === page.host)
            #expect(runtime.popupWindowOpener() == nil, "a cmux page took the extension's window")
        }
    }
}
