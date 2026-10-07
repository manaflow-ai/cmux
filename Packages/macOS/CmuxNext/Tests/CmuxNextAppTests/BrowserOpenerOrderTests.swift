import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import Testing

/// A page's new tabs go next to their opener in Chrome's order (cx-d0d.19):
/// background tabs (Cmd-click, middle click, Open Link in New Tab) after the
/// opener's last child, so they show right of the opener in click order; a
/// foreground tab right after the opener, ending earlier opener relations.
/// The fake daemon puts each tab in the slot the app names (`after`) and
/// reports the new tree before it replies, as the real one does.
@MainActor
struct BrowserOpenerOrderTests {
    /// The fake daemon's pane: its tab order and the slot of each create.
    final class Daemon {
        var order: [UInt64] = [4, 31, 32]
        var afters: [SurfaceID?] = []
        var next: UInt64 = 20

        func tree() throws -> DaemonTree {
            try DefaultChromiumTests.tree(order.filter { $0 != 4 }.map { DefaultChromiumTests.frontendTab(surface: Int($0), engine: "webkit") })
        }
    }

    @Test func linksOpenNextToTheirOpenerInChromeOrder() async throws {
        let h = try await DefaultChromiumTests().harness(cef: nil, extraTabs: [
            DefaultChromiumTests.frontendTab(surface: 31, engine: "webkit"),
            DefaultChromiumTests.frontendTab(surface: 32, engine: "webkit"),
        ])
        let daemon = Daemon()
        let store = h.services.daemon.store
        h.browserTabs.create = { _, _, _, _, _, after in
            daemon.afters.append(after)
            daemon.next += 1
            let slot = after.flatMap { daemon.order.firstIndex(of: $0.rawValue) }.map { $0 + 1 } ?? daemon.order.count
            daemon.order.insert(daemon.next, at: slot)
            store.apply(snapshot: try daemon.tree())
            return SurfaceID(rawValue: daemon.next)
        }
        let tab = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first { $0.surface == SurfaceID(rawValue: 31) })
        await BrowserTabTests.settle { h.pane.stripModel.orderedTabs.contains { $0.id.rawValue == tab.id } }
        h.pane.select(StripTabID(tab.id))
        let page = try #require(h.services.cache.browser(for: tab)).tab
        let requests = h.services.cache.pageRequests
        func open(_ path: String, _ disposition: BrowserNewTabDisposition) {
            requests.browserTab(page, didRequest: .openURL(URL(string: "https://a.test/\(path)")!, disposition))
        }
        let ids: ([UInt64]) -> [SurfaceID?] = { $0.map { SurfaceID(rawValue: $0) } }

        // Three Cmd-clicks in a row, before any reply: click order, right of the opener.
        open("1", .backgroundTab)
        open("2", .backgroundTab)
        open("3", .backgroundTab)
        await BrowserTabTests.settle { daemon.afters.count == 3 }
        #expect(daemon.afters == ids([31, 21, 22]))
        #expect(daemon.order == [4, 31, 21, 22, 23, 32])

        // A closed child is no longer one: the next goes after the last child still shown.
        daemon.order.removeAll { $0 == 23 }
        store.apply(snapshot: try daemon.tree())
        open("4", .backgroundTab)
        await BrowserTabTests.settle { daemon.afters.count == 4 }
        #expect(daemon.afters.last == SurfaceID(rawValue: 22))
        #expect(daemon.order == [4, 31, 21, 22, 24, 32])

        // A foreground tab goes right after the opener and starts a new run.
        open("5", .foregroundTab)
        await BrowserTabTests.settle { daemon.afters.count == 5 }
        #expect(daemon.afters.last == SurfaceID(rawValue: 31))
        open("6", .backgroundTab)
        await BrowserTabTests.settle { daemon.afters.count == 6 }
        #expect(daemon.afters.last == SurfaceID(rawValue: 25))
        #expect(daemon.order == [4, 31, 25, 26, 21, 22, 24, 32])

        // A tab no page asked for (New Browser Tab) still goes to the end.
        h.pane.newBrowserTab()
        await BrowserTabTests.settle { daemon.afters.count == 7 }
        #expect(daemon.afters.last == .some(nil))
        #expect(daemon.order.last == 27)
        h.teardown()
    }

    /// The slot rule alone: the opener's child furthest right of the opener;
    /// children the pane no longer shows, or shows left of the opener, do not count.
    @Test func slotIsTheRightmostShownChild() async throws {
        let openers = BrowserTabOpeners()
        let opener = SurfaceID(rawValue: 1)
        let ids = (2...5).map { SurfaceID(rawValue: $0) }
        #expect(openers.slot(after: opener, in: [opener]) == opener, "no children yet")
        for child in ids {
            _ = try await openers.place(opener: opener, foreground: false, order: { [opener] + ids }, create: { _ in child })
        }
        let order = [ids[2], opener, ids[0], ids[1], SurfaceID(rawValue: 9)]
        #expect(openers.slot(after: opener, in: order) == ids[1], "child 5 closed, child 4 sits left of the opener")
        #expect(openers.slot(after: opener, in: [opener, ids[1], ids[0]]) == ids[0], "position, not creation order")
    }
}
