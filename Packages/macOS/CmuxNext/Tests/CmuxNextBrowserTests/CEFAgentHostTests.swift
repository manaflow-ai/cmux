import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Background browser use (user 2026-11-05): an agent drives a Chromium tab its pane does not show. A pane
/// has one Chromium window and only its shown tab has the page window, so a background tab drew no frame
/// and Chromium ran its animation frames at 1 a second (viz throttles a client with undrawn frames). The
/// tab gets a window of its own in the agent render window (`cmux_tab_move_to_window`, as popups do), and
/// goes back to its pane's window when the pane shows it. Against the spare page suites' stand-in shim.
extension CEFSparePageSuites {
    @MainActor @Suite struct CEFAgentHostTests {
        typealias Fixture = CEFSparePageSuites.CEFSparePageTests

        /// The main-actor work the host queued (a window's move-in runs in a main-actor task): a test
        /// on the main actor that pumps the run loop never runs it, since the main queue does not drain
        /// inside its own job; each yield lets the queued jobs ahead of it run.
        private static func drain() async {
            for _ in 0..<8 { await Task.yield() }
        }

        private static func window(identifier: NSUserInterfaceItemIdentifier?) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1280, height: 800),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.identifier = identifier
            return window
        }

        @Test func aBackgroundTabAnAgentDrivesGetsAWindowOfItsOwnAndGoesBackToItsPane() async throws {
            let (runtime, root) = try Fixture.runtime()
            defer { Fixture.tearDown(runtime, root) }
            Fixture.setSparePage(false)
            let (home, first, container) = try Fixture.liveHost(runtime)
            let paneWindow = Self.window(identifier: nil)
            defer { paneWindow.close() }
            paneWindow.contentView?.addSubview(container)

            // A second tab of the pane, in the pane's Chromium window behind the shown one.
            let second = CEFTab(id: .random(), profile: .default, host: home, runtime: runtime)
            home.add(second)
            home.ensureCreated(second)
            let browser = try #require(second.browserID)
            #expect(SpareSpy.windows[browser] == 1)
            // The pane's content lifecycle hides its background tab.
            second.setContentVisible(false)
            SpareSpy.clearRecords()

            try #require(second.agentRelay.needsRenderWindow,
                         "a background tab of a shown pane draws no frame: an agent's call must give it the render window")

            // The App parks its content in the agent render window (`AgentRenderPanel.park`).
            let render = Self.window(identifier: .agentRenderWindow)
            defer { render.close() }
            render.contentView?.addSubview(second.contentView)
            let own = second.host
            #expect(own !== home, "the tab keeps its pane's host: presenting it there takes the page window from the pane")
            let request = try #require(runtime.pendingWindows.first { $0.value === own }?.key, "its own host made no window")
            SpareSpy.windows[40] = 4
            runtime.handle(.afterCreated(browser: 40, request: request, window: 4))
            await Self.drain()
            #expect(SpareSpy.moved.map(\.browser) == [browser], "\(SpareSpy.moved)")
            #expect(SpareSpy.moved.map(\.anchor) == [40])
            #expect(SpareSpy.windows[browser] == 4, "the tab is in its own Chromium window")
            #expect(own.visibleTab === second)
            #expect(SpareSpy.closed.contains(40), "the placeholder closed once the tab moved in")
            #expect(own.hostView.superview === second.contentView && !own.hostView.isHidden,
                    "its page window draws in the render window, though its pane hid the page")
            #expect(home.visibleTab === first && home.hostView.superview === container, "the pane still shows its own tab")

            // The pane shows the tab again: it goes back to the pane's window.
            SpareSpy.clearRecords()
            container.addSubview(second.contentView)
            #expect(second.host === home)
            #expect(SpareSpy.moved.map(\.browser) == [browser])
            #expect(SpareSpy.moved.map(\.anchor) == [10], "back next to the pane's first tab")
            #expect(SpareSpy.windows[browser] == 1)
            #expect(home.visibleTab === second && home.hostView.superview === second.contentView)
            #expect(runtime.hosts[own.key] == nil, "its own host went with its last tab")
        }

        /// A fork that cannot move the tab keeps it where it was: open and still the pane's, never closed.
        @Test func aTabTheForkCannotMoveStaysOpenInItsPane() async throws {
            let (runtime, root) = try Fixture.runtime()
            defer { Fixture.tearDown(runtime, root) }
            Fixture.setSparePage(false)
            let (home, _, container) = try Fixture.liveHost(runtime)
            let paneWindow = Self.window(identifier: nil)
            defer { paneWindow.close() }
            paneWindow.contentView?.addSubview(container)
            let second = CEFTab(id: .random(), profile: .default, host: home, runtime: runtime)
            home.add(second)
            home.ensureCreated(second)
            let browser = try #require(second.browserID)
            try #require(second.agentRelay.needsRenderWindow)
            SpareSpy.moveAnswer = 0

            let render = Self.window(identifier: .agentRenderWindow)
            defer { render.close() }
            render.contentView?.addSubview(second.contentView)
            let own = second.host
            let request = try #require(runtime.pendingWindows.first { $0.value === own }?.key)
            SpareSpy.windows[40] = 4
            runtime.handle(.afterCreated(browser: 40, request: request, window: 4))
            await Self.drain()
            #expect(!second.isClosed, "a tab that could not move closed")
            #expect(!SpareSpy.closed.contains(browser))
            #expect(second.host === home)
            #expect(SpareSpy.windows[browser] == 1)
        }
    }
}
