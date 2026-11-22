import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The icon picker and the group editor are WebKit overlay pages; making them at launch started a WebContent and a
/// GPU process (about 60 MB) at Home before anyone opened either (Leo 2026-11-14, Home idle memory). They are made on
/// the first sign of intent: the first menu (where every Set Icon and Rename Group is, `MenuTracking.onFirstMenu`)
/// and the first hover over a group header (`SidebarGroupEditor.prepareSurface`). Nothing else makes them before an open.
@MainActor
struct OverlayPagesOnIntentTests {
    @Test func theFirstMenuRunsTheWorkOnceAndNothingBefore() async {
        let center = NotificationCenter()
        let tracking = MenuTracking(center: center)
        var made = 0
        tracking.onFirstMenu { made += 1 }
        await Task.yield()
        #expect(made == 0, "the pages were made before any menu opened")

        center.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        await Self.nextTurns()
        #expect(made == 0, "a menu's end made the pages")

        center.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        #expect(made == 0, "the work ran inside the menu's begin-tracking post, holding the menu up")
        await Self.nextTurns()
        #expect(made == 1, "the first menu made no overlay page")

        center.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        await Self.nextTurns()
        #expect(made == 1, "a later menu made the pages again")
    }

    /// Each group header hover asks (a page freed after its idle limit is made again; a made one costs a check).
    @Test func eachHoverOverAGroupHeaderPreparesTheEditor() {
        let list = SidebarListView(model: SidebarModel())
        let surface = CountingSurface()
        list.groupEditor.surface = surface
        list.setHovered(.workspace(WorkspaceID("w")))
        #expect(surface.prepared == 0, "a workspace row hover prepared the group editor")
        list.setHovered(.group(GroupID("g")))
        #expect(surface.prepared == 1, "a group header hover did not prepare the group editor")
        list.setHovered(nil)
        list.setHovered(.group(GroupID("h")))
        #expect(surface.prepared == 2, "a later group header hover did not ask again")
    }

    /// Every menu runs the work (the pages are freed when unused, so a later menu makes them again), never inside the
    /// menu's own begin-tracking post.
    @Test func everyMenuRunsTheWorkOnTheNextTurn() async {
        let center = NotificationCenter()
        let tracking = MenuTracking(center: center)
        var made = 0
        tracking.onMenus { made += 1 }
        center.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        await Self.nextTurns()
        #expect(made == 0, "a menu's end made the pages")
        center.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        #expect(made == 0, "the work ran inside the menu's begin-tracking post, holding the menu up")
        await Self.nextTurns()
        #expect(made == 1)
        center.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        await Self.nextTurns()
        #expect(made == 2, "a later menu did not run the work")
    }

    @Test func aNewGroupEditorServiceMakesNoPageUntilAsked() {
        let service = GroupEditorService()
        #expect(service.panel == nil, "the group editor made its page before any open or intent")
    }

    /// The group editor's page is freed by `release` and after its idle limit with no open (CMUX-571).
    @Test func theGroupEditorFreesItsPageWhenUnused() async throws {
        let service = GroupEditorService()
        service.prepare()
        #expect(service.isWarm)
        service.release()
        #expect(!service.isWarm, "release kept the page")
        service.idleLimit = .milliseconds(50)
        service.prepare()
        #expect(service.isWarm, "a sign of intent after a release made no page")
        for _ in 0..<100 where service.isWarm { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!service.isWarm, "an unused editor page stayed made past its idle limit")
    }

    /// Lets the main actor run the work queued by a post (one ordering hop).
    private static func nextTurns() async {
        for _ in 0..<5 { await Task.yield() }
    }
}

@MainActor
private final class CountingSurface: SidebarGroupEditorSurface {
    var prepared = 0
    func present(_ group: SidebarGroup, items: [[SidebarGroupEditorItem]], anchor: PopupAnchor, parent: NSWindow,
                 themeAnchor: NSView, ordersFront: Bool, events: SidebarGroupEditorEvents) {}
    func refresh(_ group: SidebarGroup) {}
    func dismiss() {}
    func prepare() { prepared += 1 }
}
