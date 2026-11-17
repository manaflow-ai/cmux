#if DEBUG
import AppKit
import CmuxNextDesign
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

    /// A pane on its split's spring: it shows at `bounds` now and will rest at `rest` (`RestingPlacement`).
    private final class SpringingPane: NSView, RestingPlacement {
        var rest = NSSize.zero
        var restOffset: CGVector { CGVector(dx: 0, dy: bounds.height - rest.height) }
        var restContentSizeChange: CGSize? {
            let change = CGSize(width: rest.width - bounds.width, height: rest.height - bounds.height)
            return change == .zero ? nil : change
        }
    }

    /// The size (points) a size wait asks the page for: the function's arguments are `[height, width]` (sorted names).
    private static func sizeAsked(_ expression: String) -> NSSize? {
        guard let open = expression.range(of: ".apply(null, [", options: .backwards), let close = expression.lastIndex(of: "]") else { return nil }
        let values = expression[open.upperBound..<close].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return values.count == 2 ? NSSize(width: values[1], height: values[0]) : nil
    }

    /// SPLIT OPEN (2026-11-10, films of #39993 on aws-m4pro-8, 120 Hz): Cmd-Shift-D's new pane showed no chat for 75 to
    /// 84 frames (about 650 ms). Its New Tab spare is moved into the pane while the pane is on its split's spring, so
    /// its first layout there is at a size the pane leaves in the next frame (242 pt of 459 in the film's trace). The
    /// page waited outside the window for a frame at THAT size, got each later size of the spring and never drew
    /// one: the wait ended only at its bound of 60 frames. The page takes the size its pane will REST at, once, in
    /// that first layout, keeps it while the pane grows, and waits for its frame at that size.
    @Test func aPageMovedIntoAPaneOnItsSplitSpringWaitsForTheSizeThePaneRestsAt() async throws {
        let (view, page) = try await parkedChromiumPage()
        var asked: [NSSize] = []
        page.answer = { method, params in
            guard method == "Runtime.evaluate", let expression = params["expression"] as? String, expression.contains("innerWidth") else { return nil }
            if let size = Self.sizeAsked(expression) { asked.append(size) }
            return nil
        }
        view.placeMovedChromiumPage {}
        let rest = NSSize(width: 1000, height: 700)
        let window = pane(rest)
        defer { window.close() }
        // The split's first frame with the chat in it: the pane shows 300 pt of the 700 pt it will rest at.
        let springing = SpringingPane(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        springing.rest = rest
        window.contentView?.addSubview(springing)
        springing.addSubview(view)
        view.frame = springing.bounds
        view.layoutSubtreeIfNeeded()

        let atRest = view.topBar.contentFrame(in: NSRect(origin: .zero, size: rest)).size
        try #require(view.holdsPageAway, "the moved page shows at once: the test no longer reaches the wait")
        #expect(view.pageContent.frame.size == atRest,
                "the held page is laid out at \(view.pageContent.frame.size), a size of the spring, not the size its pane rests at \(atRest)")

        // The spring's next frames, in this turn (the page has not answered): the pane grows, the held page keeps the
        // one size it will show at.
        for height in [500.0, 650, 700] {
            springing.frame.size.height = height
            view.frame = springing.bounds
            view.layoutSubtreeIfNeeded()
            try #require(view.holdsPageAway)
            #expect(view.pageContent.frame.size == atRest, "the held page got the spring's size \(view.pageContent.frame.size) at pane height \(height)")
        }

        // The wait it started asks the page for a frame at the rest size, not at the first frame's size.
        let deadline = Date().addingTimeInterval(5)
        while asked.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let zoom = max(try #require(view.page).pageZoom, 0.01)
        let wanted = NSSize(width: atRest.width / zoom, height: atRest.height / zoom)
        let first = try #require(asked.first, "no size wait was asked of the page")
        #expect(abs(first.width - wanted.width) <= 1 && abs(first.height - wanted.height) <= 1,
                "the page waits for a frame at \(first), not at the size its pane rests at \(wanted): it never draws one and shows after the wait's bound")

        // Once it drew there it comes back in place at the pane's size.
        while view.holdsPageAway, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!view.holdsPageAway)
        view.layoutSubtreeIfNeeded()
        #expect(view.pageContent.frame == view.topBar.contentFrame(in: view.bounds))
    }

    /// A page that drew its frame while its pane is still on the spring does not come in at a size of the spring (it
    /// would get a new size in each of the spring's next frames): it shows in the layout the pane lands in.
    @Test func aPageThatDrewWhileItsPaneIsOnItsSpringShowsWhenThePaneLands() async throws {
        let (view, page) = try await parkedChromiumPage()
        var asked = 0
        page.answer = { method, params in
            if method == "Runtime.evaluate", let expression = params["expression"] as? String, expression.contains("innerWidth") { asked += 1 }
            return nil
        }
        view.placeMovedChromiumPage {}
        let rest = NSSize(width: 1000, height: 700)
        let window = pane(rest)
        defer { window.close() }
        let springing = SpringingPane(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        springing.rest = rest
        window.contentView?.addSubview(springing)
        springing.addSubview(view)
        view.frame = springing.bounds
        view.layoutSubtreeIfNeeded()
        try #require(view.holdsPageAway, "the moved page shows at once: the test no longer reaches the wait")

        // The page answers its size wait (the fake answers at once) while the pane is at 300 pt of 700.
        let deadline = Date().addingTimeInterval(5)
        while asked == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(asked > 0, "no size wait was asked of the page")
        try await Task.sleep(for: .milliseconds(500)) // the fake's answer comes back in a later turn
        let atRest = view.topBar.contentFrame(in: NSRect(origin: .zero, size: rest)).size
        #expect(view.holdsPageAway, "the page came in while its pane is on its spring, at \(view.pageContent.frame.size)")
        #expect(view.pageContent.frame.size == atRest)

        // The pane lands: the page shows in that layout, at the pane's size.
        springing.frame.size.height = rest.height
        view.frame = springing.bounds
        view.layoutSubtreeIfNeeded()
        #expect(!view.holdsPageAway, "the page is still outside the window after its pane landed")
        #expect(view.pageContent.frame == view.topBar.contentFrame(in: view.bounds))
    }

    /// A page parked at the size its new pane rests at needs no new frame, but its pane is still on its spring: it
    /// does not come in at a size of the spring, and no size wait is asked of it. It shows when the pane lands.
    @Test func aPageParkedAtThePanesRestSizeShowsWhenThePaneLandsWithNoSizeWait() async throws {
        let (view, page) = try await parkedChromiumPage()
        var moves = 0
        view.placeMovedChromiumPage { moves += 1 }
        let rest = NSSize(width: 800, height: 600)
        let window = pane(rest)
        defer { window.close() }
        let springing = SpringingPane(frame: NSRect(x: 0, y: 0, width: 800, height: 250))
        springing.rest = rest
        window.contentView?.addSubview(springing)
        springing.addSubview(view)
        view.frame = springing.bounds
        view.layoutSubtreeIfNeeded()

        let atRest = view.topBar.contentFrame(in: NSRect(origin: .zero, size: rest)).size
        #expect(view.holdsPageAway, "the page shows in a pane on its spring: it gets a size in each spring frame")
        #expect(view.pageContent.frame.size == atRest, "the held page is at \(view.pageContent.frame.size), not at its pane's rest size \(atRest)")
        try await Task.sleep(for: .milliseconds(200))
        #expect(sizeWaits(page) == 0, "a page already drawn at the rest size was asked to wait for a size")
        #expect(view.holdsPageAway, "the page came in while its pane is on its spring")

        springing.frame.size.height = rest.height
        view.frame = springing.bounds
        view.layoutSubtreeIfNeeded()
        #expect(!view.holdsPageAway, "the page is still outside the window after its pane landed")
        #expect(view.pageContent.frame == view.topBar.contentFrame(in: view.bounds))
        #expect(moves == 2, "the page's window was told \(moves) times, not once out and once back")
    }
}
#endif
