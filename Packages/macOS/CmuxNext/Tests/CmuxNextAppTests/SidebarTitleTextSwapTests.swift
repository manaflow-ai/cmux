import AppKit
import CmuxNextDesign
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
    func theSwapMovesNoFrame() throws {
        try Self.withMotion {
            let h = Harness()
            defer { h.close() }
            let row = try h.row(3)
            h.window.displayIfNeeded()
            let before = h.frames
            try h.patch(3) { $0.title = "A much longer name an agent gave this workspace while it worked" }
            var sawSwap = false, samples = 0
            let end = Date().addingTimeInterval(0.3)
            while Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.008))
                samples += 1
                let now = h.frames
                #expect(now == before, "sample \(samples): \(now.filter { before[$0.key] != $0.value })")
                if let shown = row.title.layer?.presentation(), shown.opacity < 0.99 || shown.transform.m42 != 0 { sawSwap = true }
            }
            #expect(samples > 10)
            #expect(sawSwap, "the title's layer showed the swap on screen")
            #expect(row.title.stringValue.hasPrefix("A much longer name"))
            #expect(Self.ghosts(row).isEmpty, "the snapshot left when its fade ended")
            #expect(Self.swapKeys(row).isEmpty, "the swap ended on its own")
        }
    }
}
