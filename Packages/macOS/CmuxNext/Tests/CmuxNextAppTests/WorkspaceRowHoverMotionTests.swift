import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-13 (cosmic-gray): moving the pointer from one workspace row to
/// the next snapped the hover state: the menu button and the x appeared and
/// vanished at once, and the fill cleared at once. Both ways now fade in
/// place (`MotionFade.hover`), keyed to the row, and nothing in the row moves
/// or resizes: the buttons keep their slots while they fade out.
@MainActor
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
    func hoverFadesTheRowsButtonsAndFillBothWaysInPlace() throws {
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
        defer { window.orderOut(nil) }
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
            #expect(Self.keyPaths(under: view.layer).contains("opacity"), "the \(name) snapped in")
        }
        #expect(Self.keyPaths(under: row.title.layer).contains("locations"), "the title's fade under the buttons snapped in")
        #expect(row.frame == rest.row && row.title.frame == rest.title, "hover moved or resized the row")
        let slots = Self.controls(row).map { $0.1.frame }

        row.isHovered = false
        row.layoutSubtreeIfNeeded()
        row.displayIfNeeded()
        for ((name, view), slot) in zip(Self.controls(row), slots) {
            #expect(!view.isHidden && view.alphaValue == 0, "the \(name) vanished instead of fading out")
            #expect(Self.keyPaths(under: view.layer).contains("opacity"), "the \(name) snapped out")
            #expect(view.frame == slot, "the \(name) left its slot as it faded out")
        }
        #expect(Self.keyPaths(under: row.layer).contains("backgroundColor"), "the hover fill cleared at once")
        #expect(row.frame == rest.row && row.title.frame == rest.title, "hover moved or resized the row")
    }

    @Test func realizationSuppressesHoverLayoutAndFadeState() {
        let model = SidebarModel(sections: [])
        let list = SidebarListView(model: model)
        let row = WorkspaceRowView(key: .workspace(WorkspaceID("realization")))
        row.sidebarList = list
        list.hoverFollowsScroll = true
        // AppKit marks a freshly constructed row for its initial layout. Clear
        // that baseline before asserting that realization does not enqueue a
        // second hover layout or fade.
        row.layoutSubtreeIfNeeded()

        row.isHovered = true

        #expect(!row.needsLayout, "scroll realization must not schedule hover layout")
        #expect(!row.fadesNextFill, "scroll realization must not leave a fill fade queued")
        #expect(!row.fadesNextHover, "scroll realization must not leave a hover fade queued")
    }
}
