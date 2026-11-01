import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing
import CmuxNextTestSupport

/// Leo 2026-10-13 (cosmic-gray): moving the pointer from one workspace row to
/// the next snapped the hover state. Hover entry is immediate; clearing the
/// fill uses the hover-out token (instant by default), and nothing in the row
/// moves or resizes. Since Leo 2026-10-20 the controls clear at once too: no
/// exit delay on hover-out, so the old row's buttons never trail the pointer.
@MainActor
@Suite(.closesItsWindows)
struct WorkspaceRowHoverMotionTests {
    private static let name = "a workspace whose name runs under the hover buttons"

    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// Every animation key path on `layer` and the layers under it, masks included
    /// (the title's fade is its text layer's mask).
    private static func keyPaths(under layer: CALayer?) -> [String] {
        guard let layer else { return [] }
        let own = (layer.animationKeys() ?? []).compactMap { (layer.animation(forKey: $0) as? CAPropertyAnimation)?.keyPath }
        return own + ((layer.sublayers ?? []) + [layer.mask].compactMap { $0 }).flatMap { keyPaths(under: $0) }
    }

    /// The row's hover buttons, by name.
    private static func controls(_ row: WorkspaceRowView) -> [(String, NSView)] {
        [("x", row.closeButton), ("menu", row.moreButton)]
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func hoverShowsRowsButtonsImmediatelyAndClearsInPlace() throws {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, resourceID: ResourceID(rawValue: "ws-long"), name: Self.name),
        ]))
        let section = SidebarMapping.shared.sections(store.sidebarSections,
                                                     machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))[0]
        let id = section.workspaces[0].id
        let model = SidebarModel(sections: [CmuxNextSidebar.SidebarSection(kind: section.kind, nodes: [.workspace(section.workspaces[0])])])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.contextMenuProvider = { _ in NSMenu() }
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        let row = try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)

        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let rest = (row: row.frame, title: row.title.frame)

        row.isHovered = true
        row.layoutSubtreeIfNeeded()
        row.displayIfNeeded()
        for (name, view) in Self.controls(row) {
            #expect(!view.isHidden, "the \(name) shows on hover")
            #expect(!Self.keyPaths(under: view.layer).contains("opacity"), "the \(name) should show immediately")
        }
        #expect(!Self.keyPaths(under: row.title.layer).contains("locations"), "the title fade should not delay hover entry")
        #expect(!Self.keyPaths(under: row.layer).contains("backgroundColor"), "the hover fill should show immediately")
        #expect(row.frame == rest.row && row.title.frame == rest.title, "hover moved or resized the row")
        let slots = Self.controls(row).map { $0.1.frame }

        row.isHovered = false
        row.layoutSubtreeIfNeeded()
        row.displayIfNeeded()
        for ((name, view), slot) in zip(Self.controls(row), slots) {
            #expect(view.isHidden || view.alphaValue == 0, "the \(name) stayed after hover left")
            #expect(!Self.keyPaths(under: view.layer).contains("opacity"), "the \(name) faded out instead of clearing at once")
            #expect(view.isHidden || view.frame == slot, "the \(name) left its slot")
        }
        #expect(!Self.keyPaths(under: row.layer).contains("backgroundColor"), "the hover fill should clear without a trail")
        #expect(row.frame == rest.row && row.title.frame == rest.title, "hover moved or resized the row")
    }

    /// Leo 2026-10-18 (NEXT nightly): a row kept its x after the pointer left it. A list reload
    /// (any model change, a workspace switch) clears hover while hover effects are suppressed, and
    /// the row's controls only show or hide in `layout()`, which that path no longer requested.
    @Test func hoverClearedDuringAReloadHidesTheRowsControls() throws {
        let workspaces = [
            SidebarWorkspace(id: WorkspaceID("workspace-1"), title: "Workspace 1"),
            SidebarWorkspace(id: WorkspaceID("workspace-2"), title: "Workspace 2"),
        ]
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })])
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: 240, height: 300)
        list.reload(animated: false)
        let key = SidebarRowKey.workspace(workspaces[0].id)
        let row = try #require(list.rowViews[key] as? WorkspaceRowView)
        list.setHovered(key)
        row.layoutSubtreeIfNeeded()
        #expect(!row.closeButton.isHidden && row.closeButton.alphaValue > 0, "the x shows on hover")

        // No window, so the reload finds no pointer over the list and clears hover while applying.
        list.reload(animated: false)
        row.layoutSubtreeIfNeeded()

        #expect(list.hoveredKey == nil)
        #expect(!row.isHovered)
        #expect(row.closeButton.isHidden || row.closeButton.alphaValue == 0, "the x stayed after hover cleared")
    }

    @Test func removingTheHoveredRowClearsItsTransientState() throws {
        let workspaces = [
            SidebarWorkspace(id: WorkspaceID("workspace-1"), title: "Workspace 1"),
            SidebarWorkspace(id: WorkspaceID("workspace-2"), title: "Workspace 2"),
        ]
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let section = SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })
        let model = SidebarModel(sections: [section])
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: 240, height: 300)
        list.reload(animated: false)
        let old = try #require(list.rowViews[.workspace(workspaces[0].id)] as? WorkspaceRowView)
        old.isHovered = true
        list.hoveredKey = .workspace(workspaces[0].id)

        model.sections = [SidebarSection(kind: .machine(machine), nodes: [.workspace(workspaces[1])])]
        list.reload(animated: true)

        #expect(list.hoveredKey == nil)
        #expect(!old.isHovered)
        #expect(!old.fadesNextFill)
        #expect(!old.fadesNextHover)
    }
}
