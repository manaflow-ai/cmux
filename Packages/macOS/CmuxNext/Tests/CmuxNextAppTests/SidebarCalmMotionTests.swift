import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// POLISH audit, batch 4 (cx-2grmt): "No bouncy or weird transforms." A mouse wheel past the
/// first or last space bounced the list out and back, and a new group's chip grew from 0.86.
/// The edge stays still, and the chip arrives with its row's fade only.
@MainActor @Suite(.closesItsWindows)
struct SidebarCalmMotionTests {
    private static let group = GroupID("grp-new")

    /// A sidebar with one workspace; `grouped` puts it in a New Group.
    private static func sections(grouped: Bool) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, resourceID: ResourceID(rawValue: "ws-notes"), name: "notes"),
        ]))
        let section = SidebarMapping.shared.sections(store.sidebarSections,
                                                     machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))[0]
        let notes = section.workspaces[0]
        let node: CmuxNextSidebar.SidebarNode = grouped ? .group(SidebarGroup(id: group, name: "New Group", workspaces: [notes])) : .workspace(notes)
        return [CmuxNextSidebar.SidebarSection(kind: section.kind, nodes: [node])]
    }

    private static func sidebar(_ model: SidebarModel) -> SidebarView {
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    /// Every animation on `layer` and the layers under it.
    private static func animations(under layer: CALayer?) -> [CAAnimation] {
        guard let layer else { return [] }
        let own = (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }
        return own + (layer.sublayers ?? []).flatMap { animations(under: $0) }
    }

    @Test func aWheelPastTheLastSpaceLeavesTheListStill() {
        let model = SidebarModel(sections: Self.sections(grouped: false))
        model.profiles = [SidebarProfile(id: ProfileKey("work"), name: "Work"), SidebarProfile(id: ProfileKey("home"), name: "Home")]
        model.activeProfileID = ProfileKey("home")
        let sidebar = Self.sidebar(model)
        // Synchronous: the override is process-wide.
        let moved = { () -> Bool in
            Motion.reduceMotionOverride = false
            defer { Motion.reduceMotionOverride = nil }
            sidebar.scrollView.onWheelPage?(1)
            return !Self.animations(under: sidebar.scrollView.layer).isEmpty
        }()
        #expect(!moved, "the list bounced at the last space")
        #expect(model.activeProfileID == ProfileKey("home"))
    }

    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// The rows open in a window on screen: with no screen Motion snaps them.
    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aNewGroupsChipFadesInWithoutGrowing() throws {
        let model = SidebarModel(sections: Self.sections(grouped: false))
        let sidebar = Self.sidebar(model)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        sidebar.layoutSubtreeIfNeeded()
        let scaled = try { () throws -> [String] in
            Motion.reduceMotionOverride = false
            defer { Motion.reduceMotionOverride = nil }
            model.sections = Self.sections(grouped: true)
            sidebar.list.reload(animated: true)
            let header = try #require(sidebar.list.rowViews[.group(Self.group)] as? GroupHeaderRowView)
            return Self.animations(under: header.layer).compactMap { ($0 as? CAPropertyAnimation)?.keyPath }
                .filter { $0.contains("scale") }
        }()
        #expect(scaled.isEmpty, "the chip grew in: \(scaled)")
    }
}
