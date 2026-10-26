import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import QuartzCore
import Testing

/// p03-rendering-103: a section reorder in a band, a Priority rank change and a scroll to a row set each
/// model frame (or the clip's origin) once, in the change's turn, and the render server's additive `.move`
/// springs carry what shows (`SidebarDragSpring`). AppKit's `animator()` spring wrote every moving view's frame,
/// or the clip's bounds, on the main thread each display frame: frames 2..n of the motion counted one frame or
/// bounds change per moving view. Counted here with AppKit's own change notifications, which every such write posts.
@MainActor @Suite(.serialized)
struct SidebarFrameAnimatorsOnRenderServerTests {
    /// The motion-off check only needs a screen.
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// The additive springs the render server runs on `view`'s layer.
    private static func springs(_ view: NSView) -> Int {
        guard let layer = view.layer else { return 0 }
        return (layer.animationKeys() ?? []).filter { key in (layer.animation(forKey: key) as? CASpringAnimation)?.isAdditive ?? false }.count
    }

    /// Counts `name` posts from each of `objects` while `body` runs (each view posts them; `postsFrameChangedNotifications`
    /// and `postsBoundsChangedNotifications` are turned on first).
    private static func counting(_ name: Notification.Name, from objects: [NSView], _ body: () async throws -> Void) async rethrows -> Int {
        for object in objects {
            object.postsFrameChangedNotifications = true
            object.postsBoundsChangedNotifications = true
        }
        let counter = PostCounter()
        let tokens = objects.map { object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { _ in counter.add() }
        }
        defer { tokens.forEach(NotificationCenter.default.removeObserver) }
        try await body()
        return counter.count
    }

    /// Lets the display run its frames for `duration` (the motion's frames 2..n).
    private static func runFrames(for duration: Duration) async throws {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(16)) }
    }

    /// Runs `body` with Reduce Motion pinned to `reduceMotion` and every animation switch on.
    private static func withMotion<T>(reduceMotion: Bool = false, _ body: () async throws -> T) async rethrows -> T {
        let design = DesignSettings.shared
        let (enabled, categories) = (design.animationsEnabled, design.disabledAnimationCategories)
        Motion.reduceMotionOverride = reduceMotion
        design.animationsEnabled = true
        design.disabledAnimationCategories.remove(.sidebar)
        defer {
            Motion.reduceMotionOverride = nil
            design.animationsEnabled = enabled
            design.disabledAnimationCategories = categories
        }
        return try await body()
    }

    /// A window on screen showing `view` (with no screen Motion snaps every change).
    private static func window(showing view: NSView, height: CGFloat) throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: height), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.wantsLayer = true
        window.contentView?.addSubview(view)
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        view.layoutSubtreeIfNeeded()
        return window
    }

    // MARK: Section reorder in a band

    private static let sectionA = LayoutSectionID("sec_a"), sectionB = LayoutSectionID("sec_b")

    private static func band(_ order: [LayoutSectionID]) -> SidebarRegionView.Content {
        let sections = order.map { id in
            LayoutSection(id: id, title: id.rawValue, region: .top, items: (1...2).map { n in
                LayoutItem(id: LayoutItemID("\(id.rawValue)_\(n)"), ref: .url("https://example.com/\(id.rawValue)/\(n)"))
            })
        }
        return SidebarRegionView.Content(sections: sections, infos: [:], collapsed: [], look: SidebarSectionTunables.currentLook,
                                         metrics: .standard, drawsLines: false)
    }

    /// The item a band row draws, if any.
    private static func item(of kind: SidebarRegionRow.Kind) -> LayoutItemID? {
        switch kind {
        case let .item(id, _), let .tile(id, _), let .chip(id, _): id
        default: nil
        }
    }

    @Test(.enabled("needs a display that draws frames and animations on, or every change snaps anyway") {
        await GUIAnimationTestSupport.animatesHere()
    })
    func aSectionReorderSetsEachFrameOnceAndSpringsOnTheRenderServer() async throws {
        try await Self.withMotion {
            let region = SidebarRegionView(region: .top)
            region.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
            let content = Self.band([Self.sectionA, Self.sectionB])
            region.update(content, width: 240)
            let window = try Self.window(showing: region, height: 400)
            defer { window.orderOut(nil) }
            let items = content.sections.flatMap(\.items).map(\.id)
            let views = try items.map { id in try #require(region.itemView(id), "the band draws no \(id.rawValue)") }
            let reordered = Self.band([Self.sectionB, Self.sectionA])
            let targets = SidebarRegionView.layout(of: reordered, width: 240).rows

            region.reorderSections = reordered.sections
            region.relayout(animated: true)
            // The change's own turn: every item is at its new slot, the render server carries what shows.
            for (id, view) in zip(items, views) {
                let target = try #require(targets.first { Self.item(of: $0.kind) == id }, "the reordered band has no \(id.rawValue)")
                #expect(view.frame == target.frame, "\(id.rawValue) is at \(view.frame), its slot is \(target.frame)")
                #expect(Self.springs(view) > 0, "\(id.rawValue) did not move on the render server")
            }
            let later = try await Self.counting(NSView.frameDidChangeNotification, from: views) {
                try await Self.runFrames(for: .milliseconds(300))
            }
            #expect(later == 0, "the main thread wrote \(later) item frames in the motion's later frames")
        }
    }

    // MARK: Priority rank change

    private static func panel(_ ids: [String]) -> SidebarPriorityPanel {
        SidebarPriorityPanel(entries: ids.map { SidebarPriorityEntry(id: $0, title: $0, preview: nil, state: .idle) })
    }

    private static func rows(in view: NSView) -> [SidebarPriorityRowView] {
        view.subviews.flatMap { ($0 as? SidebarPriorityRowView).map { [$0] } ?? rows(in: $0) }
    }

    @Test(.enabled("needs a display that draws frames and animations on, or every change snaps anyway") {
        await GUIAnimationTestSupport.animatesHere()
    })
    func aPriorityRankChangeSetsEachFrameOnceAndSpringsOnTheRenderServer() async throws {
        try await Self.withMotion {
            let view = SidebarPriorityPanelView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
            view.show(Self.panel(["a", "b", "c", "d"]))
            let window = try Self.window(showing: view, height: 600)
            defer { window.orderOut(nil) }
            let rows = Self.rows(in: view)
            try #require(rows.count == 4)
            let height = try #require(rows.first).frame.height

            view.show(Self.panel(["d", "c", "b", "a"]))
            for row in rows {
                let rank = try #require(["d", "c", "b", "a"].firstIndex(of: row.entry.id))
                #expect(row.frame.minY == CGFloat(rank) * height, "\(row.entry.id) is not at its new slot in the change's turn: \(row.frame)")
                #expect(Self.springs(row) > 0, "\(row.entry.id) did not move on the render server")
            }
            let later = try await Self.counting(NSView.frameDidChangeNotification, from: rows) {
                try await Self.runFrames(for: .milliseconds(300))
            }
            #expect(later == 0, "the main thread wrote \(later) row frames in the motion's later frames")
        }
    }

    // MARK: Scroll to a row

    private static func sidebar(rows count: Int) throws -> (SidebarView, NSWindow) {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let workspaces = (1...count).map { CmuxNextSidebar.SidebarWorkspace(id: WorkspaceID("w\($0)"), title: "w\($0)") }
        let sections = [CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })]
        let model = SidebarModel(sections: sections, activeWorkspaceID: workspaces.first?.id)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 320)
        let window = try Self.window(showing: sidebar, height: 320)
        sidebar.list.reload(animated: false)
        return (sidebar, window)
    }

    @Test(.enabled("needs a display that draws frames and animations on, or every change snaps anyway") {
        await GUIAnimationTestSupport.animatesHere()
    })
    func aScrollToARowSetsTheOriginOnceAndSpringsTheDocumentLayer() async throws {
        try await Self.withMotion {
            let (sidebar, window) = try Self.sidebar(rows: 40)
            defer { window.orderOut(nil) }
            let list = sidebar.list
            let clip = try #require(list.enclosingScrollView?.contentView)
            let row = try #require(list.displayed.row(for: .workspace(WorkspaceID("w8"))))

            list.scrollClip(to: row.y, animated: true)
            #expect(abs(clip.bounds.minY - row.y) < 0.5, "the clip is at \(clip.bounds.minY), not at \(row.y), in the scroll's turn")
            #expect(Self.springs(list) == 1, "the scroll did not move the content on the render server")
            #expect(list.rowViews[.workspace(WorkspaceID("w8"))] != nil, "the row scrolled to is not realized")
            let later = try await Self.counting(NSView.boundsDidChangeNotification, from: [clip]) {
                try await Self.runFrames(for: .milliseconds(300))
            }
            #expect(later == 0, "the main thread moved the clip \(later) times in the scroll's later frames")
            #expect(abs(clip.bounds.minY - row.y) < 0.5)
        }
    }

    /// A person's scroll takes over at once: the programmatic scroll's spring comes off.
    @Test(.enabled("needs a display that draws frames and animations on, or every change snaps anyway") {
        await GUIAnimationTestSupport.animatesHere()
    })
    func aWheelScrollEndsAScrollSpring() async throws {
        try await Self.withMotion {
            let (sidebar, window) = try Self.sidebar(rows: 40)
            defer { window.orderOut(nil) }
            let list = sidebar.list
            let row = try #require(list.displayed.row(for: .workspace(WorkspaceID("w8"))))
            list.scrollClip(to: row.y, animated: true)
            try #require(Self.springs(list) == 1, "the scroll did not move the content on the render server")
            sidebar.scrollView.stopContentSpring()
            #expect(Self.springs(list) == 0, "the scroll's spring kept running under the person's scroll")
        }
    }

    /// With movement off a scroll to a row lands in one frame: no spring.
    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aScrollWithMovementOffLandsAtOnce() async throws {
        try await Self.withMotion(reduceMotion: true) {
            let (sidebar, window) = try Self.sidebar(rows: 40)
            defer { window.orderOut(nil) }
            let list = sidebar.list
            let clip = try #require(list.enclosingScrollView?.contentView)
            let row = try #require(list.displayed.row(for: .workspace(WorkspaceID("w8"))))
            list.scrollClip(to: row.y, animated: true)
            #expect(abs(clip.bounds.minY - row.y) < 0.5)
            #expect(Self.springs(list) == 0, "the content springs with movement off")
        }
    }
}

/// Notification posts counted on the main thread (AppKit posts view frame and bounds changes there).
@MainActor
private final class PostCounter: Sendable {
    private(set) var count = 0
    nonisolated func add() { MainActor.assumeIsolated { count += 1 } } // main-proof: NSView posts frame and bounds changes on the main thread, delivered synchronously (queue: nil)
}
