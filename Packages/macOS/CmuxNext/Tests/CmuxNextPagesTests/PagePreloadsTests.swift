import AppKit
import CmuxNextCompat
import CmuxNextInputCore
import CmuxNextInputCoreTestSupport
@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The Settings, History and Cloud coordinator on the app's one preload slot (``PagePreloads``):
/// nothing preloads at launch; an open names the page, which preloads once input is
/// quiet, into an empty slot only (it never evicts New Tab's page, and arms again
/// when the slot empties); no page preloads while its owner keeps a view that the next open shows;
/// a preload boots with the document attributes a cold open uses, and an open with others opens cold.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PagePreloadsTests {
    typealias FakePage = PagePreloadSlotTests.FakePage
    typealias FakeParking = PagePreloadSlotTests.FakeParking

    /// A value a test changes while the coordinator reads it.
    @MainActor final class Box {
        var flag = false
        var layout = "cards"
    }

    /// The requests the coordinator opened, in order.
    @MainActor final class Opened {
        var requests: [PageOpenRequest] = []
    }

    private let base: PagePreloadPageTests

    init() throws {
        base = try PagePreloadPageTests()
    }

    /// A coordinator over `host`'s slot whose target is `content` at the test size; its opens are
    /// recorded in `opened` and served the test's own page (first-party pages are served only from
    /// their bundle).
    private func makePreloads(host: WebUIHost, content: NSView, tap: FakeInputTap, opened: Opened,
                              enabled: @escaping @MainActor () -> Bool = { true },
                              attributes: @escaping @MainActor (PagePreloads.Page) -> [String: String] = { _ in [:] },
                              keepsView: @escaping @MainActor (PagePreloads.Page) -> Bool = { _ in false }) throws -> PagePreloads {
        let slot = try #require(host.preload)
        let root = base.root, descriptor = base.descriptor
        return PagePreloads(webUI: host, slot: slot, deadlines: base.rig.scheduler, input: tap, isEnabled: enabled,
                            target: { (content, PagePreloadPageTests.size) }, documentAttributes: attributes,
                            keepsView: keepsView) { [weak host] request in
            opened.requests.append(request)
            var own = request
            own.descriptor = descriptor
            own.root = root
            return host?.open(own)
        }
    }

    /// Fires every pending deadline (the slot's cover limits and the quiet-input wait).
    private func fireAll() {
        var fires = 0
        while base.rig.queue.count > 0, fires < 8 {
            base.rig.fire()
            fires += 1
        }
    }

    /// The coordinator: nothing preloads at launch; an open names the page, which preloads once input
    /// is quiet (a key pushes it back), and the next open takes it in its own turn, bound to that
    /// open. Off, no open is claimed.
    @Test func theNextOpenOfAPageTakesItsPreloadAfterQuietInput() throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let window = PagePreloadPageTests.shownWindow()
        defer { window.close() }
        let content = try #require(window.contentView)
        let tap = FakeInputTap()
        let host = base.makeHost(nil)
        let enabled = Box()
        enabled.flag = true
        let preloads = try makePreloads(host: host, content: content, tap: tap, opened: Opened(), enabled: { enabled.flag })
        preloads.start()
        #expect(base.rig.queue.count == 0, "a preload was armed before any open")

        // The first open finds nothing and names the page.
        #expect(preloads.claim(.history, routes: []) == nil)
        #expect(preloads.next == .history && base.rig.queue.count == 1)
        tap.deliver(InputEventRecord(type: .keyDown, timestamp: 1))
        #expect(base.rig.queue.count == 1, "a key pushes the one deadline back")
        base.rig.fire()
        let held = try #require(preloads.heldPage)
        #expect(held.descriptor == base.descriptor && held.isPooled && held.isParkedSpare && held.window === window)
        #expect(host.preload?.key == PagePreloads.Page.history.key)

        // Another page's open leaves the History preload alone; History's own open takes it.
        #expect(preloads.claim(.cloud, routes: []) == nil)
        #expect(preloads.heldPage === held)
        let claimed = try #require(preloads.claim(.history, routes: [], route: "/today"))
        #expect(claimed === held && claimed.isClaimed && claimed.route == "#/today")
        #expect(host.preload?.count == 0)
        host.close(claimed)

        // A closing window drops the page waiting in it.
        fireAll()
        #expect(preloads.heldPage != nil)
        preloads.windowWillClose(window)
        #expect(preloads.heldPage == nil && host.preload?.count == 0)

        enabled.flag = false
        #expect(preloads.claim(.history, routes: []) == nil)
        #expect(preloads.debugReport(action: nil)["enabled"] == .bool(false))
    }

    /// The slot holds New Tab's page: a Settings open and quiet input leave it there (the last caller
    /// used to evict it, and Cmd-T then loaded cold). Once Cmd-T takes it, Settings preloads.
    @Test func aPreloadNeverEvictsNewTabAndPreloadsWhenTheSlotEmpties() throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let window = PagePreloadPageTests.shownWindow()
        defer { window.close() }
        let content = try #require(window.contentView)
        let host = base.makeHost(nil)
        let slot = try #require(host.preload)
        let newTab = FakePage("newTab")
        slot.preload(PagePreloadSlotTests.newTab, size: PagePreloadPageTests.size, in: FakeParking()) { _ in newTab }
        newTab.paint()
        newTab.cover()
        let opened = Opened()
        let preloads = try makePreloads(host: host, content: content, tap: FakeInputTap(), opened: opened)
        preloads.start()

        #expect(preloads.claim(.settings, routes: []) == nil)
        #expect(preloads.next == .settings)
        fireAll()
        #expect(slot.key == PagePreloadSlotTests.newTab && !newTab.closed, "a Settings preload evicted New Tab's page")
        #expect(opened.requests.isEmpty && preloads.heldPage == nil)
        #expect(preloads.debugReport(action: "preload")["key"] == .string(PagePreloadSlotTests.newTab.rawValue))
        #expect(!newTab.closed, "debug.page_preload preload evicted New Tab's page")

        let tab = NSView(frame: NSRect(origin: .zero, size: PagePreloadPageTests.size))
        content.addSubview(tab)
        _ = try #require(slot.claim(PagePreloadSlotTests.newTab, into: tab, frame: tab.bounds))
        newTab.claimed = true
        fireAll()
        let held = try #require(preloads.heldPage, "the emptied slot did not arm the Settings preload again")
        #expect(slot.key == PagePreloads.Page.settings.key && opened.requests.count == 1)
        host.close(held)
    }

    /// Settings, opened, closed and opened again: its owner shows the page it kept, so no Settings
    /// preload waits unclaimed (it would hold a renderer and the one slot). Other pages still preload.
    @Test func noSettingsPreloadWhileItsKeptPageShowsAgain() throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let window = PagePreloadPageTests.shownWindow()
        defer { window.close() }
        let content = try #require(window.contentView)
        let host = base.makeHost(nil)
        let kept = Box()
        let opened = Opened()
        let preloads = try makePreloads(host: host, content: content, tap: FakeInputTap(), opened: opened,
                                        keepsView: { page in page == .settings && kept.flag })
        preloads.start()

        // The first open is cold; its owner keeps the page from then on (SettingsWindowService.keepsPage).
        #expect(preloads.claim(.settings, routes: []) == nil)
        kept.flag = true
        fireAll()
        #expect(opened.requests.isEmpty && host.preload?.count == 0)

        // Closed and opened again: the kept page shows, and still no Settings preload is held.
        #expect(preloads.claim(.settings, routes: []) == nil)
        fireAll()
        #expect(opened.requests.isEmpty && host.preload?.count == 0)

        #expect(preloads.claim(.history, routes: []) == nil)
        fireAll()
        let held = try #require(preloads.heldPage)
        #expect(opened.requests.count == 1)
        host.close(held)
    }

    /// Cloud's page reads its machine list layout once, at mount: the preload boots with the layout
    /// a cold open uses, so a claim shows the setting; a preload that booted with another layout (the
    /// setting changed while it waited) is dropped at the open, which opens cold, and the next
    /// preload boots with the new layout.
    @Test func aCloudPreloadBootsWithTheLayoutAColdOpenUses() throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let window = PagePreloadPageTests.shownWindow()
        defer { window.close() }
        let content = try #require(window.contentView)
        let host = base.makeHost(nil)
        let setting = Box()
        let attributes: @MainActor (PagePreloads.Page) -> [String: String] = { page in
            page == .cloud ? ["cloud-machines-layout": setting.layout] : [:]
        }
        let opened = Opened()
        let preloads = try makePreloads(host: host, content: content, tap: FakeInputTap(), opened: opened, attributes: attributes)
        preloads.start()

        #expect(preloads.claim(.cloud, routes: [], documentAttributes: attributes(.cloud)) == nil)
        fireAll()
        let held = try #require(preloads.heldPage)
        #expect(opened.requests.last?.documentAttributes == ["cloud-machines-layout": "cards"], "the preload booted with the default layout")
        #expect(held.userContent.userScripts.contains {
            $0.source.contains("cloud-machines-layout") && $0.source.contains("cards")
        })
        let claimed = try #require(preloads.claim(.cloud, routes: [], documentAttributes: attributes(.cloud)))
        #expect(claimed === held)
        host.close(claimed)

        fireAll()
        let stale = try #require(preloads.heldPage)
        setting.layout = "rows"
        #expect(preloads.claim(.cloud, routes: [], documentAttributes: attributes(.cloud)) == nil,
                "a preload that booted with the old layout was claimed")
        #expect(preloads.heldPage !== stale)
        fireAll()
        let fresh = try #require(preloads.heldPage)
        #expect(opened.requests.last?.documentAttributes == ["cloud-machines-layout": "rows"])
        let reclaimed = try #require(preloads.claim(.cloud, routes: [], documentAttributes: attributes(.cloud)))
        #expect(reclaimed === fresh)
        host.close(fresh)
    }
}
