import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// R99 in the sidebar: a horizontal swipe shows the real rows of the space
/// beside (from `spaceSections`), a flick switches to it once the page has
/// settled, and the real list then takes the page's place with no second
/// slide. A switch by dot slides in from the side of its dot.
@MainActor @Suite(.serialized) struct SidebarSpacePagingTests {
    static let keys = ["a", "b", "c"].map(ProfileKey.init)

    static func sidebar() -> (SidebarView, NSWindow) {
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Local", kind: .local)),
                                                           nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("ws-b"), title: "ws-b"))])])
        model.profiles = keys.map { SidebarProfile(id: $0, name: $0.rawValue) }
        model.activeProfileID = keys[1]
        model.spaceSections = { key in
            [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Local", kind: .local)),
                            nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("ws-\(key.rawValue)"), title: "ws-\(key.rawValue)"))])]
        }
        let view = SidebarView(model: model)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        view.list.reload(animated: false)
        return (view, window)
    }

    @Test func aFlickShowsTheNextSpacesRowsThenSwitchesToIt() async throws {
        let (view, window) = Self.sidebar()
        defer { window.close() }
        var intents: [SidebarIntent] = []
        view.model.onIntent = { intents.append($0) }
        let paging = view.spacePaging
        paging.scroll(.began, deltaX: -10, time: 1.00)
        paging.scroll(.changed, deltaX: -60, time: 1.03)
        paging.scroll(.changed, deltaX: -60, time: 1.06)
        let neighbor = try #require(paging.neighbor)
        #expect(neighbor.index == 2)
        #expect(neighbor.list.displayed.row(for: .workspace(WorkspaceID("ws-c"))) != nil, "the real rows of the next space")
        paging.scroll(.ended, deltaX: 0, time: 1.07)
        for _ in 0..<200 where intents.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(intents == [.switchProfile(Self.keys[2])])
        // The model shows the next space: the page gives way to the real list.
        view.model.sections = neighbor.list.model.sections
        view.switchSpace(from: Self.keys[1], to: Self.keys[2], profiles: view.model.profiles)
        #expect(paging.neighbor == nil && paging.pendingTarget == nil)
        #expect(view.list.displayed.row(for: .workspace(WorkspaceID("ws-c"))) != nil)
    }

    @Test func aSlowShortSwipeReturns() async throws {
        let (view, window) = Self.sidebar()
        defer { window.close() }
        var intents: [SidebarIntent] = []
        view.model.onIntent = { intents.append($0) }
        let paging = view.spacePaging
        paging.scroll(.began, deltaX: 20, time: 1.0)
        paging.scroll(.changed, deltaX: 20, time: 1.5)
        #expect(paging.neighbor?.index == 0)
        paging.scroll(.ended, deltaX: 0, time: 2.0)
        try await Task.sleep(for: .milliseconds(800))
        #expect(intents.isEmpty)
        #expect(paging.neighbor == nil)
    }

    /// Live run (sbr99-v1): the neighbor page took the hit tests, so the
    /// rest of the swipe went to it and the list stopped following. The
    /// pages never take events; the gesture stays on the list's scroll view.
    @Test func theNeighborPageNeverTakesTheGesture() throws {
        let (view, window) = Self.sidebar()
        defer { window.close() }
        let paging = view.spacePaging
        paging.scroll(.began, deltaX: -20, time: 1.0)
        #expect(paging.neighbor != nil)
        let inList = view.scrollView.convert(NSPoint(x: 60, y: view.scrollView.bounds.midY), to: view.superview)
        let hit = try #require(view.hitTest(inList))
        #expect(hit.isDescendant(of: view.scrollView), "hit \(type(of: hit))")
    }

    /// Live run (sbr99-v1): the list's scroll view sits inside the edge
    /// fade view, so a page added to the sidebar itself had the wrong
    /// coordinates and stayed under the fade: the next space never showed.
    /// Pages are siblings of the list, on its frame, above it.
    @Test func theNeighborPageIsASiblingOfTheListOnItsFrame() throws {
        let (view, window) = Self.sidebar()
        defer { window.close() }
        let paging = view.spacePaging
        paging.scroll(.began, deltaX: -20, time: 1.0)
        let page = try #require(paging.neighbor?.view)
        let list = view.scrollView
        #expect(page.superview === list.superview)
        #expect(page.frame == list.frame)
        // Live run: the page was not flipped, so its rows sat at the bottom.
        let rows = try #require(paging.neighbor?.list)
        #expect(page.isFlipped && rows.frame.minY == 0, "the next space's rows start at the top")
        let siblings = list.superview?.subviews ?? []
        #expect((siblings.firstIndex(of: page) ?? -1) > (siblings.firstIndex(of: list) ?? Int.max))
    }

    /// Live run (sbr99-v1): the kept page of a slide drew no text (an image
    /// of layer-backed rows). It is now a page of the old space's real rows.
    @Test func aSlideKeepsTheOldSpacesRealRows() throws {
        let (view, window) = Self.sidebar()
        defer { window.close() }
        let old = view.model.sections
        view.model.sections = view.model.spaceSections?(Self.keys[2]) ?? []
        view.switchSpace(from: Self.keys[1], to: Self.keys[2], profiles: view.model.profiles, oldSections: old)
        let kept = try #require(view.spacePaging.snapshotView as? SpacePageView)
        #expect(kept.list?.displayed.row(for: .workspace(WorkspaceID("ws-b"))) != nil, "the old space's rows")
        #expect(kept.superview === view.scrollView.superview)
    }
}
