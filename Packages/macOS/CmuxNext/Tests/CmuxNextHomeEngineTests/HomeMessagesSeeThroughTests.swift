import AppKit
@testable import CmuxNextHome
import CmuxNextPages
import CmuxNextSettings
import Testing

/// The see-through Chief's host half on a Messages page (``HomeMessagesSeeThrough``), ported from the native
/// transcript's `clearsBackground` and `HomeHostView.chiefHeaderHeight`: the switch the page follows, the header
/// height it reports, and the panel laid again when that height changes.
@MainActor
struct HomeMessagesSeeThroughTests {
    @Test func theStreamSendsTheSwitchNowAndOnEachChangeOnly() {
        let look = HomeMessagesSeeThrough()
        var events: [JSONValue] = []
        let subscription = look.subscribe { events.append($0) }
        #expect(events == [.object(["showsThrough": .bool(false)])], "off by default, sent on subscribe")
        look.showsThrough = true
        look.showsThrough = true
        look.showsThrough = false
        #expect(events == [false, true, false].map { JSONValue.object(["showsThrough": .bool($0)]) }, "one event per change")
        #expect(!look.showsThrough)
        _ = subscription
    }

    @Test func theHeaderReportIsKeptInPointsAtThePagesZoom() throws {
        let look = HomeMessagesSeeThrough()
        #expect(look.headerHeight(zoom: 1) == 0, "no header before the page reports one")
        var changes = 0
        look.onHeaderHeight = { changes += 1 }
        #expect(try look.call(HomeMessagesSeeThrough.headerOp, ["height": .number(72)]) == .null)
        #expect(look.headerHeight(zoom: 1) == 72)
        #expect(look.headerHeight(zoom: 1.25) == 90, "CSS px times the page zoom")
        _ = try look.call(HomeMessagesSeeThrough.headerOp, ["height": .number(72)])
        #expect(changes == 1, "the same height lays the panel out once")
        _ = try look.call(HomeMessagesSeeThrough.headerOp, ["height": .number(5000)])
        #expect(look.headerCSSHeight == HomeMessagesSeeThrough.maxHeaderHeight, "a header taller than any page is kept at the cap")
        #expect(changes == 2)
    }

    @Test func aBadHeaderIsRefusedAndOtherOpsAreNotItsOwn() throws {
        let look = HomeMessagesSeeThrough()
        for bad: JSONValue in [.string("72"), .number(-1), .null] {
            #expect(throws: PageError.self) { try look.call(HomeMessagesSeeThrough.headerOp, ["height": bad]) }
        }
        #expect(throws: PageError.self) { try look.call(HomeMessagesSeeThrough.headerOp, [:]) }
        #expect(try look.call("appearance", ["height": .number(1)]) == nil)
        #expect(look.headerCSSHeight == 0)
    }

    @Test func aHeaderChangeLaysOutTheNearestMatchingAncestorOnly() {
        let panel = NSView(), body = NSView(), page = NSView()
        panel.addSubview(body)
        body.addSubview(page)
        panel.layoutSubtreeIfNeeded()
        panel.needsLayout = false
        body.needsLayout = false
        HomeMessagesSeeThrough.relayout(from: page) { $0 === panel }
        #expect(panel.needsLayout)
        #expect(!body.needsLayout, "only the panel lays out")
        // No panel above: nothing is marked.
        let loose = NSView(), child = NSView()
        loose.addSubview(child)
        loose.needsLayout = false
        HomeMessagesSeeThrough.relayout(from: child) { _ in false }
        #expect(!loose.needsLayout)
    }
}
