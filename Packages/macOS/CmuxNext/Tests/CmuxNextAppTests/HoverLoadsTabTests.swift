import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// "just hovering on tab should immediately load the tab if it is not loaded alr" (Lawrence, 2026-11-11).
/// A tab whose content was never made (a tab restored at launch, or opened in the background) loaded only on its
/// click: the strip's hover went to browser hibernation alone, which wakes pages that exist (`cache.browsers`) and
/// only with `browser.wakeTabsOnHover`, so a never-shown tab stayed empty until the click and the click waited for
/// its page or terminal. Now a rest on the tab for the hover dwell (`HoverWakeIntent.dwell`, 100 ms) makes its
/// content hidden, and a pointer that only crosses it makes nothing.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct HoverLoadsTabTests {
    /// A pane with a terminal and a browser tab the app draws, whose page was never made.
    @MainActor struct Fixture {
        let services: AppServices
        let controller: PaneController
        let page: String

        init() throws {
            services = IncognitoSurfacesTests.services()
            let tabs = [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "shell"),
                        TabSnapshot(surface: 2, kind: .browser, title: "Blank", url: "about:blank", browserRenderer: "frontend")]
            let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: tabs)
            let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
            services.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey.generate(),
                                                                                            name: "hover", screens: [screen])]))
            let model = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
            controller = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services,
                                        state: WindowState(record: record))
            page = try #require(model.tabs.first { $0.kind == .browser }).id
            try #require(services.cache.existingBrowser(page) == nil, "the page exists before any hover")
        }

        func close() {
            controller.teardown()
            services.cache.release(page)
        }
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "\(what) never happened")
    }

    @Test func aRestOnANeverShownTabMakesItsPage() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.controller.noteHover(StripTabID(fixture.page))
        try await until("the hovered tab's page is made") { fixture.services.cache.existingBrowser(fixture.page) != nil }
        #expect(fixture.services.cache.presenter(of: fixture.page) == nil, "the hover showed the page instead of making it hidden")
    }

    @Test func aPointerThatOnlyCrossesTheTabMakesNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.controller.noteHover(StripTabID(fixture.page))
        fixture.controller.noteHover(nil)
        try await Task.sleep(for: .milliseconds(400)) // four dwells with the pointer off the strip
        #expect(fixture.services.cache.existingBrowser(fixture.page) == nil, "a pass over the tab made its page")
    }
}
