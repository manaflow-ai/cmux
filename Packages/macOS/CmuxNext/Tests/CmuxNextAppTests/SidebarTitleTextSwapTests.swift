import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo 2026-11-08: "i feel like when workspaces get renamed (esp by agents) it should have that same fade in
/// animation that the tool call situation has". A rename that reaches a shown row through the row patch path
/// (`SidebarModel.patchWorkspaces` -> `SidebarListView.patchRows`) swaps its title as the agent chat's live line
/// swaps a tool call (the old words rise and fade as a snapshot layer, the new ones rise in): the title's layer
/// carries the swap and the snapshot lies over it. Leo 2026-10-31: "WE DON'T NEED A FADE IN ANIMATION UNLESS IT'S
/// THE WORST CASE": first paint, a reload, a row scrolled back into view (a reused view) and a `sidebar.rowTitle`
/// mode or breadcrumb change show the title at once. The row keeps its width and no row moves while it plays.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarTitleTextSwapTests {
    /// The swap's layer names (`MotionGate.textSwapGhostName`, `.textSwapOpacityKey`, `.textSwapRiseKey`).
    static let ghostName = "cmux.textSwap.ghost"
    static let swapKeyPrefix = "cmux.textSwap"

    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// Turns the run loop for `seconds` (the frames commit and the swap advances); a synchronous call, since
    /// `RunLoop.run(until:)` is not available from an async test.
    static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    final class Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        let ids: [WorkspaceID]
        var list: SidebarListView { sidebar.list }

        /// `count` loose workspaces in a sidebar `height` points tall, on screen.
        init(count: Int = 7, height: CGFloat = 600, tabs: Bool = false) {
            _ = NSApplication.shared
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            ids = (0..<count).map { WorkspaceID("ts-\($0)") }
            let rows = ids.enumerated().map { index, id in
                var ws = SidebarWorkspace(id: id, title: "Workspace \(index)", tabs: tabs ? [
                    SidebarTab(id: TabID("\(id.rawValue)-a"), title: "zsh"),
                    SidebarTab(id: TabID("\(id.rawValue)-b"), title: "Pull request", kind: .browser),
                ] : [])
                ws.focusedTab = tabs ? TabID("\(id.rawValue)-a") : nil
                return ws
            }
            model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: rows.map { .workspace($0) })],
                                 activeWorkspaceID: ids.first)
            sidebar = SidebarView(model: model, design: DesignSettings())
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 260, height: height), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: height)
            window.contentView = sidebar
            window.orderFrontRegardless()
            sidebar.renderNow()
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
            sidebar.layoutSubtreeIfNeeded()
            // Drawn once, as a row the person reads has been: AppKit hangs a view's layer under its parent's
            // at the first display, and a title never drawn changes at once (it was not seen).
            window.displayIfNeeded()
        }

        func close() { window.closeAfterTest() }

        func row(_ index: Int) throws -> WorkspaceRowView {
            try #require(list.rowViews[.workspace(ids[index])] as? WorkspaceRowView, "row \(index) has no view")
        }

        /// The list's copy of workspace `index`, changed by `edit`, sent through the real patch path.
        @discardableResult
        func patch(_ index: Int, _ edit: (inout SidebarWorkspace) -> Void) throws -> SidebarWorkspace {
            var ws = try #require(list.workspaces[ids[index]])
            edit(&ws)
            #expect(model.patchWorkspaces([ws]), "the patch is not structural")
            return ws
        }

        /// Every realized row's frame, and each workspace row's title frame.
        var frames: [String: NSRect] {
            var frames: [String: NSRect] = [:]
            for (key, view) in list.rowViews {
                frames["\(key)"] = view.frame
                if let row = view as? WorkspaceRowView { frames["\(key).title"] = row.title.frame }
            }
            return frames
        }

        func scroll(to y: CGFloat) {
            let clip = sidebar.scrollView.contentView
            clip.scroll(to: NSPoint(x: 0, y: y))
            sidebar.scrollView.reflectScrolledClipView(clip)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    /// The title's swap animations (the new words arriving).
    static func swapKeys(_ row: WorkspaceRowView) -> [String] {
        (row.title.layer?.animationKeys() ?? []).filter { $0.hasPrefix(swapKeyPrefix) }
    }

    /// The old words' snapshot layers over the title.
    static func ghosts(_ row: WorkspaceRowView) -> [CALayer] {
        (row.layer?.sublayers ?? []).filter { $0.name == ghostName }
    }

    /// Any title motion at all: the swap, its snapshot, or the old CATransition variants.
    static func moves(_ row: WorkspaceRowView) -> Bool {
        !swapKeys(row).isEmpty || !ghosts(row).isEmpty || row.title.layer?.animation(forKey: "workspace-title-motion") != nil
    }

    static func withMotion(_ body: () throws -> Void) throws {
        let previous = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = previous }
        try #require(Motion.sidebar.animatesMovement, "sidebar motion is off on this host")
        try body()
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aRenameThroughThePatchPathSwapsTheTitle() throws {
        try Self.withMotion {
            let h = Harness()
            defer { h.close() }
            let row = try h.row(3)
            #expect(row.title.stringValue == "Workspace 3")
            try h.patch(3) { $0.title = "Fix the flaky login test" }
            #expect(row.title.stringValue == "Fix the flaky login test", "the new words are in the view at once")
            #expect(Set(Self.swapKeys(row)) == ["cmux.textSwap.opacity", "cmux.textSwap.rise"],
                    "the new words rise in: \(row.title.layer?.animationKeys() ?? [])")
            #expect(Self.ghosts(row).count == 1, "the old words lie over the title as one snapshot")
            #expect(row.title.layer?.animation(forKey: "workspace-title-motion") == nil, "no second animation")
            for other in [0, 1, 2, 4, 5, 6] {
                #expect(try !Self.moves(h.row(other)), "row \(other) did not change")
            }
        }
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func firstPaintAndAPatchThatKeepsTheNameSwapNothing() throws {
        try Self.withMotion {
            let h = Harness()
            defer { h.close() }
            for index in h.ids.indices { #expect(try !Self.moves(h.row(index)), "row \(index) on first paint") }
            // A patch that changes the row's other content (a status tick) keeps its name still.
            try h.patch(2) { $0.status = "Running tests" }
            #expect(try !Self.moves(h.row(2)))
        }
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aReloadSwapsNothing() throws {
        try Self.withMotion {
            let h = Harness()
            defer { h.close() }
            let row = try h.row(3)
            var sections = h.model.sections
            sections[0].nodes = sections[0].nodes.map { node in
                guard case var .workspace(ws) = node, ws.id == h.ids[3] else { return node }
                ws.title = "Restored name"
                return .workspace(ws)
            }
            h.model.sections = sections
            h.sidebar.renderNow()
            h.list.reload(animated: false)
            h.sidebar.layoutSubtreeIfNeeded()
            let shown = try h.row(3)
            #expect(shown.title.stringValue == "Restored name")
            #expect(!Self.moves(shown) && !Self.moves(row), "a reload (a restore, a structural set) shows the name at once")
        }
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aRowScrolledBackIntoViewSwapsNothing() throws {
        try Self.withMotion {
            let h = Harness(count: 80, height: 300)
            defer { h.close() }
            _ = try h.row(0)
            h.scroll(to: max(0, h.list.frame.height - 300))
            #expect(h.list.rowViews[.workspace(h.ids[0])] == nil, "the first row left the realized rows")
            // Renamed while it has no view: the list keeps the new content for when it scrolls in.
            try h.patch(0) { $0.title = "Renamed off screen" }
            h.scroll(to: 0)
            let row = try h.row(0)
            #expect(row.title.stringValue == "Renamed off screen")
            #expect(!Self.moves(row), "a reused view scrolled into view shows its name at once")
            // The same view, renamed again now that it shows: that swap is real.
            try h.patch(0) { $0.title = "Renamed in view" }
            #expect(!Self.swapKeys(row).isEmpty, "a rename of the shown row swaps")
        }
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func theOldWordsFadeOverTheWholeOutDuration() throws {
        try Self.withMotion {
            let h = Harness()
            defer { h.close() }
            let row = try h.row(3)
            try h.patch(3) { $0.title = "Fix the flaky login test" }
            let ghost = try #require(Self.ghosts(row).first, "the old words lie over the title")
            let out = try #require(ghost.animation(forKey: "cmux.textSwap.out") as? CAAnimationGroup, "the old words rise and fade")
            let children = out.animations ?? []
            #expect(children.count == 2, "a fade and a rise")
            // A child with no duration of its own runs 0.25 s inside the group and is clipped at its end, still showing.
            for child in children {
                #expect(abs(child.duration - out.duration) < 1e-9,
                        "\((child as? CAPropertyAnimation)?.keyPath ?? "?") spans \(child.duration) s of the group's \(out.duration) s")
            }
            // As `useTextSwap.ts`: gone at `TextSwapMotion.goneAt` of the out duration, and still gone at its end.
            let fade = try #require(children.compactMap { $0 as? CAKeyframeAnimation }.first { $0.keyPath == "opacity" })
            #expect(fade.keyTimes?.map(\.doubleValue) == [0, TextSwapMotion.goneAt, 1])
            #expect((fade.values as? [Double])?.suffix(2) == [0, 0], "fully transparent from goneAt to the end")
        }
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func rapidRenamesDropTheOldestSnapshots() throws {
        try Self.withMotion {
            let h = Harness()
            defer { h.close() }
            let row = try h.row(3)
            // Three renames in one turn of the run loop: no fade ends between them.
            try h.patch(3) { $0.title = "First name" }
            let first = try #require(Self.ghosts(row).first)
            try h.patch(3) { $0.title = "Second name" }
            let second = try #require(Self.ghosts(row).first { $0 !== first }, "the second rename left its own snapshot")
            try h.patch(3) { $0.title = "Third name" }
            let ghosts = Self.ghosts(row)
            #expect(ghosts.count <= MotionScale.textSwapMaxGhosts, "at most \(MotionScale.textSwapMaxGhosts) snapshots: \(ghosts.count)")
            #expect(!ghosts.contains { $0 === first }, "the oldest snapshot went")
            #expect(ghosts.contains { $0 === second }, "the newer snapshot stays")
            #expect(ghosts.contains { $0 !== first && $0 !== second }, "the newest snapshot stays")
            #expect(row.title.stringValue == "Third name")
        }
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aRowScrolledAwayAndBackUnchangedSwapsItsNextRename() throws {
        try Self.withMotion {
            let h = Harness(count: 80, height: 300)
            defer { h.close() }
            let original = try h.row(0)
            h.scroll(to: max(0, h.list.frame.height - 300))
            #expect(h.list.rowViews[.workspace(h.ids[0])] == nil, "the first row left the realized rows")
            h.scroll(to: 0)
            let row = try h.row(0)
            // Its own parked view, with its content kept (`keepsContentOnReturn`): configure changes nothing.
            try #require(row === original, "the first row took back its own view")
            #expect(row.title.stringValue == "Workspace 0")
            #expect(!Self.moves(row), "coming back into view moves nothing")
            try h.patch(0) { $0.title = "Renamed after scrolling back" }
            #expect(row.title.stringValue == "Renamed after scrolling back")
            #expect(Set(Self.swapKeys(row)) == ["cmux.textSwap.opacity", "cmux.textSwap.rise"],
                    "a rename of the row back in view swaps: \(row.title.layer?.animationKeys() ?? [])")
        }
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aRowTitleModeOrBreadcrumbChangeSwapsNothing() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let key = SidebarTunables.rowTitle.key
        defer {
            TunableStore.shared.set(key, nil)
            SidebarTunablesWatch.shared.changed()
        }
        try Self.withMotion {
            let h = Harness(tabs: true)
            defer { h.close() }
            let row = try h.row(2)
            #expect(row.title.stringValue == "Workspace 2")
            TunableStore.shared.set(key, SidebarRowTitleMode.breadcrumb.tunableValue)
            SidebarTunablesWatch.shared.changed()
            #expect(row.title.stringValue == "Workspace 2 › zsh")
            #expect(!Self.moves(row), "a mode change redraws the name at once")
            // The breadcrumb's tab changes through the patch path: the workspace's name did not.
            try h.patch(2) { $0.focusedTab = TabID("\(h.ids[2].rawValue)-b") }
            #expect(row.title.stringValue == "Workspace 2 › Pull request")
            #expect(!Self.moves(row), "a new focused tab is not a rename")
            // A rename under the breadcrumb mode swaps.
            try h.patch(2) { $0.title = "Release notes" }
            #expect(row.title.stringValue == "Release notes › Pull request")
            #expect(!Self.swapKeys(row).isEmpty, "a rename in breadcrumb mode swaps")
        }
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func theSwapMovesNoFrame() async throws {
        let previous = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = previous }
        try #require(Motion.sidebar.animatesMovement, "sidebar motion is off on this host")
        do {
            let h = Harness()
            defer { h.close() }
            let row = try h.row(3)
            h.window.displayIfNeeded()
            let before = h.frames
            try h.patch(3) { $0.title = "A much longer name an agent gave this workspace while it worked" }
            var sawSwap = false, samples = 0
            let end = Date().addingTimeInterval(0.3)
            while Date() < end {
                Self.spin(0.008)
                samples += 1
                let now = h.frames
                #expect(now == before, "sample \(samples): \(now.filter { before[$0.key] != $0.value })")
                if let shown = row.title.layer?.presentation(), shown.opacity < 0.99 || shown.transform.m42 != 0 { sawSwap = true }
            }
            #expect(samples >= 5, "the run loop turned \(samples) times")
            #expect(sawSwap, "the title's layer showed the swap on screen")
            #expect(row.title.stringValue.hasPrefix("A much longer name"))
            // Awaited, not a spun run loop: the fade's completion comes on the main queue this test runs on.
            try await MotionTextSwapTests.until(deadline: 1) { Self.ghosts(row).isEmpty }
            #expect(Self.ghosts(row).isEmpty, "the snapshot left when its fade ended")
            #expect(Self.swapKeys(row).isEmpty, "the swap ended on its own")
        }
    }
}
