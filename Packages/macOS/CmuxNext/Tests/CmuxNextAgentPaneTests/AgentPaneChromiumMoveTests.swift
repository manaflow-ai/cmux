#if DEBUG
import AppKit
import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Leo 2026-11-03: "when i make a new workspace (new tab area) it is blank for a split second then the
/// composer comes for a split second and it grows or shrinks to a size for a split second". The New Tab
/// spare shows in Chromium, whose page draws in its own window: moved into a pane, that window must be
/// told to follow it in the first layout there, and a page parked at another size must not show until
/// it drew at the pane's size.
@Suite(.serialized, .closesItsWindows)
@MainActor
struct AgentPaneChromiumMoveTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A Chromium page parked at 800 x 600, out of any window.
    private func parkedChromiumPage() async throws -> (AgentPaneView, FakeChromiumPage) {
        let file = try #require(AgentPageTestRoot.page)
        let hosting = FakeChromiumHosting()
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), pageHost: true, testRoot: true,
                                              chromium: hosting))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(5)
        while !view.debugShowsChromium, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(view.debugShowsChromium)
        return (view, try #require(hosting.made.last))
    }

    private func pane(_ size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        return window
    }

    private func sizeWaits(_ page: FakeChromiumPage) -> Int {
        page.calls.filter { $0.method == "Runtime.evaluate" && ($0.params["expression"] as? String)?.contains("innerWidth") == true }.count
    }

    @Test func aPageParkedAtThePanesSizeShowsInPlaceInItsFirstLayout() async throws {
        let (view, page) = try await parkedChromiumPage()
        var moves = 0
        view.placeMovedChromiumPage { moves += 1 }
        let window = pane(NSSize(width: 800, height: 600))
        defer { window.close() }
        window.contentView?.addSubview(view)
        view.frame = window.contentView!.bounds
        view.layoutSubtreeIfNeeded()

        #expect(moves == 1)
        #expect(!view.holdsPageAway)
        #expect(view.pageContent.frame == view.topBar.contentFrame(in: view.bounds))
        #expect(sizeWaits(page) == 0)
        // Later layouts do not tell the window again.
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        #expect(moves == 1)
    }

    @Test func aPageParkedAtAnotherSizeWaitsOutsideTheWindowUntilItDrewThere() async throws {
        let (view, page) = try await parkedChromiumPage()
        var asked = false
        page.answer = { method, params in
            guard method == "Runtime.evaluate", (params["expression"] as? String)?.contains("innerWidth") == true else { return nil }
            asked = true
            return nil
        }
        var moves = 0
        view.placeMovedChromiumPage { moves += 1 }
        let window = pane(NSSize(width: 1000, height: 700))
        defer { window.close() }
        window.contentView?.addSubview(view)
        view.frame = window.contentView!.bounds
        view.layoutSubtreeIfNeeded()

        // Laid out at the pane's size, outside the window, its window told: nothing of it shows yet.
        let final = view.topBar.contentFrame(in: view.bounds)
        #expect(moves == 1)
        #expect(view.holdsPageAway)
        #expect(view.pageContent.frame == AgentPaneView.awayFrame(of: final))

        // Once the page drew at that size it comes back in place, its window told again.
        let deadline = Date().addingTimeInterval(5)
        while view.holdsPageAway, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(asked)
        #expect(sizeWaits(page) == 1)
        #expect(!view.holdsPageAway)
        #expect(moves == 2)
        view.layoutSubtreeIfNeeded()
        #expect(view.pageContent.frame == final)
    }
}
#endif
