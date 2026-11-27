import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-11-10: "changing spaces in sidebar also feels kinda slow". A switch by dot, key, wheel, palette
/// or CLI showed the new space's rows only after the old space's page had slid out (a 0.2 s spring), and built
/// that page (a second list: its layout and its row views) on every switch. The list now shows the new space's
/// rows at rest in the frame of the switch: no page beside it, nothing in flight. Only a trackpad swipe moves
/// pages, with the fingers.
@MainActor
struct SidebarSpaceSwitchAtRestTests {
    typealias Fixture = SidebarSpacePageRealizationTests

    /// A sidebar on "space0" that has drawn once, as a window's has before any switch.
    static func sidebar() -> (SidebarModel, SidebarView) {
        let (model, sidebar) = Fixture.sidebar()
        sidebar.renderNow()
        return (model, sidebar)
    }

    /// The space pages in the sidebar's view tree.
    static func pages(in view: NSView) -> [SpacePageView] {
        view.subviews.flatMap { ($0 as? SpacePageView).map { [$0] } ?? pages(in: $0) }
    }

    /// As the app's rows pass does (`SidebarBridge`): the new space and its rows in one change, drawn in the caller's turn.
    static func show(_ space: String, _ model: SidebarModel, _ sidebar: SidebarView) {
        model.sections = Fixture.sections(space)
        model.activeProfileID = ProfileKey(space)
        sidebar.renderNow()
    }

    /// Whether the list is in its place with no page motion on it (`SidebarSpacePaging` moves it by a layer
    /// translation under this key: a spring, or a hold off its place).
    static func listIsAtRest(_ sidebar: SidebarView) -> Bool {
        guard let layer = sidebar.scrollView.layer else { return true }
        let shift = (layer.value(forKeyPath: "transform.translation.x") as? NSNumber)?.doubleValue ?? 0
        return layer.animation(forKey: "spacePaging.translation") == nil && shift == 0
    }

    @Test func aSwitchShowsTheNewSpacesRowsAtRestWithNoPageBesideThem() {
        let (model, sidebar) = Self.sidebar()
        Self.show("space1", model, sidebar)
        // No await and no run loop turn since the switch: this is what its frame draws.
        #expect(sidebar.list.displayed.rows.contains { $0.key == .workspace(WorkspaceID("space1-0")) }, "the list does not show the new space's rows")
        #expect(sidebar.list.rowViews[.workspace(WorkspaceID("space1-0"))] != nil, "the new space's first row has no view")
        #expect(!sidebar.list.displayed.rows.contains { $0.key == .workspace(WorkspaceID("a-0")) }, "the list still shows the old space's rows")
        #expect(Self.pages(in: sidebar).isEmpty, "a page of the old space is beside the list: the switch slides")
        #expect(Self.listIsAtRest(sidebar), "the list is in flight after the switch")
    }

    /// A mouse wheel notch over the list or the dots steps one space: at rest too.
    @Test func aWheelNotchShowsTheNextSpaceAtRest() {
        let (model, sidebar) = Self.sidebar()
        sidebar.spacePaging.page(by: 1)
        #expect(model.activeProfileID == ProfileKey("space1"))
        sidebar.renderNow()
        #expect(Self.pages(in: sidebar).isEmpty, "a page of the old space is beside the list: the wheel step slides")
        #expect(Self.listIsAtRest(sidebar), "the list is in flight after the wheel step")
    }

    /// Every switch in a row lands at rest: none leaves a page for the next one to clear.
    @Test func switchesInARowEachLandAtRest() {
        let (model, sidebar) = Self.sidebar()
        for space in ["space1", "space0", "space1"] {
            Self.show(space, model, sidebar)
            #expect(sidebar.list.displayed.rows.contains { $0.key == .workspace(WorkspaceID("\(space)-0")) })
            #expect(Self.pages(in: sidebar).isEmpty && Self.listIsAtRest(sidebar), "the switch to \(space) is not at rest")
        }
    }

    /// The finger-driven swipe keeps its page: the space beside comes in with the fingers, the release settles,
    /// and the list takes the page's place when the model shows the space.
    @Test func aTrackpadSwipeStillBringsTheNextSpacesPageWithTheFingers() {
        let (model, sidebar) = Self.sidebar()
        sidebar.spacePaging.scroll(.began, deltaX: -180, time: 0)
        #expect(Self.pages(in: sidebar).count == 1, "the swipe shows no page beside the list")
        #expect(!Self.listIsAtRest(sidebar), "the list does not follow the fingers")
        sidebar.spacePaging.scroll(.ended, deltaX: 0, time: 0.1)
        #expect(sidebar.spacePaging.pendingTarget == ProfileKey("space1"))
        Self.show("space1", model, sidebar)
        #expect(sidebar.spacePaging.pendingTarget == nil && sidebar.spacePaging.neighbor == nil)
        #expect(Self.pages(in: sidebar).isEmpty && Self.listIsAtRest(sidebar), "the swipe's page stays after the model shows its space")
        #expect(sidebar.list.displayed.rows.contains { $0.key == .workspace(WorkspaceID("space1-0")) })
    }
}
