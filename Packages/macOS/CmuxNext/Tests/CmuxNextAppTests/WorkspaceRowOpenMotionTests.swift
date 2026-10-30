import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo's sidebar item B ask: "the new row icon grows/fades in" while the rows below slide on
/// the same roughly 150 ms spring. This is a behavior test for the existing row insertion path.
@MainActor @Suite(.serialized, .closesItsWindows)
struct WorkspaceRowOpenMotionTests {
    private static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    private static func sections(_ icon: WorkspaceIcon?) -> [SidebarSection] {
        let one = SidebarWorkspace(id: WorkspaceID("one"), title: "one")
        let two = SidebarWorkspace(id: WorkspaceID("two"), title: "two", icon: icon)
        return [SidebarSection(kind: .machine(machine), nodes: [.workspace(one), .workspace(two)])]
    }

    private static func sidebar(_ model: SidebarModel) -> SidebarView {
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    private static func animations(under layer: CALayer?) -> [CAAnimation] {
        guard let layer else { return [] }
        return (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }
            + (layer.sublayers ?? []).flatMap { animations(under: $0) }
    }

    @Test func aNewWorkspaceIconGrowsAndFadesIn() throws {
        let model = SidebarModel(sections: Self.sections(nil))
        let sidebar = Self.sidebar(model)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        sidebar.layoutSubtreeIfNeeded()

        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        model.sections = Self.sections(.symbol("star", tint: nil))
        sidebar.list.reload(animated: true)
        let row = try #require(sidebar.list.rowViews[.workspace(WorkspaceID("two"))] as? WorkspaceRowView)
        let keys = Self.animations(under: row.icon.layer).compactMap { ($0 as? CAPropertyAnimation)?.keyPath }
        #expect(keys.contains("transform.scale"), "new workspace icon did not grow: \(keys)")
        #expect(keys.contains("opacity"), "new workspace icon did not fade: \(keys)")
    }
}
