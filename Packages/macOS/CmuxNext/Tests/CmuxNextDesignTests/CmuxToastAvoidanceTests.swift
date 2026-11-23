import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Each window's link from its avoided views to the toast hosts that show toasts there
/// (`CmuxToastAvoidance`): a change in one window reaches only that window's hosts, and a window
/// that shows no toast does no work (the app-wide notice woke every host for every window).
@MainActor
@Suite(.closesItsWindows)
struct CmuxToastAvoidanceTests {
    private static func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                 backing: .buffered, defer: true)
    }

    /// Each window's change reaches the host registered there, not another window's host, and a
    /// window with no host starts no task.
    @Test func anAvoidanceChangeReachesOnlyTheHostOfItsWindow() async {
        let windows = [Self.window(), Self.window()]
        let quiet = Self.window()
        defer { (windows + [quiet]).forEach { $0.closeAfterTest() } }
        let spyA = ReanchorSpy(), spyB = ReanchorSpy()
        CmuxToastAvoidance.register(spyA, in: windows[0])
        CmuxToastAvoidance.register(spyB, in: windows[1])

        await CmuxToastAvoidance.avoidanceChanged(in: windows[0])?.value
        #expect(spyA.reanchored.map { $0 === windows[0] } == [true], "window A's host missed its own window's change")
        #expect(spyB.reanchored.isEmpty, "window B's host was reached for window A's change")

        await CmuxToastAvoidance.avoidanceChanged(in: windows[1])?.value
        #expect(spyA.reanchored.count == 1)
        #expect(spyB.reanchored.map { $0 === windows[1] } == [true], "window B's host missed its own window's change")

        let quietWorked = CmuxToastAvoidance.avoidanceChanged(in: quiet) != nil
        #expect(!quietWorked, "a window with no toast host did work")
        CmuxToastAvoidance.unregister(spyA, from: windows[0])
        CmuxToastAvoidance.unregister(spyB, from: windows[1])
    }

    /// Two hosts in the same window both hear its change: a later host does not take the window
    /// from an earlier one. When the last leaves, the window's next change starts no task.
    @Test func everyHostInTheWindowHearsUntilTheLastLeaves() async throws {
        let window = Self.window()
        defer { window.closeAfterTest() }
        let first = ReanchorSpy(), second = ReanchorSpy()
        CmuxToastAvoidance.register(first, in: window)
        CmuxToastAvoidance.register(second, in: window)

        let move = try #require(CmuxToastAvoidance.avoidanceChanged(in: window), "no host was reached")
        await move.value
        #expect(first.reanchored.count == 1 && second.reanchored.count == 1)

        CmuxToastAvoidance.unregister(first, from: window)
        let stillShowing = try #require(CmuxToastAvoidance.avoidanceChanged(in: window),
                                        "the window's remaining host no longer hears its changes")
        await stillShowing.value
        #expect(first.reanchored.count == 1, "a host that left still heard the change")
        #expect(second.reanchored.count == 2)

        CmuxToastAvoidance.unregister(second, from: window)
        let afterLastWorked = CmuxToastAvoidance.avoidanceChanged(in: window) != nil
        #expect(!afterLastWorked, "a window with no toast left still starts a task per change")
    }

    /// A reserving view that comes into a window with no toasts hears at once that none shows;
    /// with a host there, the host tells it where its toasts rest.
    @Test func aReservingViewMovedInHearsWhereTheToastsRest() {
        let window = Self.window()
        defer { window.closeAfterTest() }
        let chat = ReservingSpy(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        CmuxToastAvoidance.reservingViewMoved(chat, to: window)
        #expect(chat.reports == [nil], "the view was not told that no toast shows")

        let host = ReanchorSpy()
        CmuxToastAvoidance.register(host, in: window)
        CmuxToastAvoidance.reservingViewMoved(chat, to: window)
        #expect(host.settledViews.count == 1 && host.settledViews.first === chat, "the host was not asked to tell the view")
        #expect(chat.reports == [nil], "the link told the view itself while a host shows toasts")
        CmuxToastAvoidance.unregister(host, from: window)
    }

    /// A toast's floor is above every shown avoided view in the window, a gap clear; a hidden one or
    /// none leaves it at the bottom.
    @Test func theFloorClearsTheAvoidedViews() throws {
        let window = Self.window()
        defer { window.closeAfterTest() }
        let content = try #require(window.contentView)
        let bounds = content.bounds
        #expect(CmuxToastAvoidance.floor(width: 200, in: bounds, window: window) == bounds.minY)

        let composer = AvoidedView(frame: NSRect(x: 100, y: 0, width: 400, height: 60))
        content.addSubview(composer)
        #expect(CmuxToastAvoidance.floor(width: 200, in: bounds, window: window) == 60 + CmuxToastAvoidance.avoidanceGap)

        composer.isHidden = true
        #expect(CmuxToastAvoidance.floor(width: 200, in: bounds, window: window) == bounds.minY, "a hidden view lifted the toast")
    }

    /// The floor does not follow the layout across the window (Leo 2026-11-21: "it's also affected by
    /// layout. which makes it shift"): a chat's composer that a divider drag or a sidebar toggle slides
    /// from under the toast to beside it, or to the window's other edge, leaves the toast where it was.
    @Test func theFloorStaysWhenTheLayoutMovesAnAvoidedViewAcross() throws {
        let window = Self.window()
        defer { window.closeAfterTest() }
        let content = try #require(window.contentView)
        let bounds = content.bounds
        let composer = AvoidedView(frame: NSRect(x: bounds.midX - 150, y: 0, width: 300, height: 90))
        content.addSubview(composer)
        let under = CmuxToastAvoidance.floor(width: 300, in: bounds, window: window)
        #expect(under == 90 + CmuxToastAvoidance.avoidanceGap)

        for x in [bounds.minX, bounds.maxX - 120, bounds.midX + 40] {
            composer.frame = NSRect(x: x, y: 0, width: 120, height: 90)
            #expect(CmuxToastAvoidance.floor(width: 300, in: bounds, window: window) == under, "the toast moved when the composer slid to x \(x)")
        }
        for width in [120.0, 300, 640] {
            #expect(CmuxToastAvoidance.floor(width: width, in: bounds, window: window) == under, "a toast's width changed where it rests")
        }
    }

    /// Every reserving view in the window is found, a hidden one too (it still hears the toasts went).
    @Test func reservingViewsFindsHiddenOnes() throws {
        let window = Self.window()
        defer { window.closeAfterTest() }
        let content = try #require(window.contentView)
        let shown = ReservingSpy(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let hidden = ReservingSpy(frame: NSRect(x: 300, y: 0, width: 300, height: 400))
        hidden.isHidden = true
        let holder = NSView(frame: content.bounds)
        holder.addSubview(hidden)
        content.addSubview(shown)
        content.addSubview(holder)
        let found = CmuxToastAvoidance.reservingViews(in: window)
        #expect(found.count == 2)
        #expect(found.contains { $0 === shown } && found.contains { $0 === hidden })
    }
}

@MainActor
private final class AvoidedView: NSView, CmuxToastAvoiding {
    var toastAvoidanceRect: NSRect { bounds }
}

/// Records every toast rect it is told (nil: none shows).
@MainActor
private final class ReservingSpy: NSView, CmuxToastReserving {
    private(set) var reports: [NSRect?] = []
    func toastsSettled(in rect: NSRect?, duration: TimeInterval) { reports.append(rect) }
}

/// Records each window it is asked to reanchor in, and each view it is asked to tell.
@MainActor
private final class ReanchorSpy: CmuxToastReanchoring {
    private(set) var reanchored: [NSWindow] = []
    private(set) var settledViews: [any CmuxToastReserving] = []
    func reanchor(in window: NSWindow) { reanchored.append(window) }
    func settled(in window: NSWindow, only view: any CmuxToastReserving) { settledViews.append(view) }
}
