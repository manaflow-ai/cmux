import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The motion-only brief: the new icon grows/fades on the new row’s short fade while existing rows snap to their slots.
@MainActor @Suite(.serialized, .closesItsWindows)
struct WorkspaceRowOpenMotionTests {
    private static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    private static func sections(_ icon: WorkspaceIcon?, includeSecond: Bool = true) -> [SidebarSection] {
        let one = SidebarWorkspace(id: WorkspaceID("one"), title: "one")
        let two = SidebarWorkspace(id: WorkspaceID("two"), title: "two", icon: icon)
        var nodes: [SidebarNode] = [.workspace(one)]
        if includeSecond { nodes.append(.workspace(two)) }
        return [SidebarSection(kind: .machine(machine), nodes: nodes)]
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

    @Test(.enabled("needs an awake display and animations on") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    }, arguments: [false, true])
    func aNewWorkspaceIconGrowsAndFadesInUnlessMotionIsReduced(reduceMotion: Bool) throws {
        let model = SidebarModel(sections: Self.sections(nil, includeSecond: false))
        let sidebar = Self.sidebar(model)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        try #require(sidebar.list.rowViews[.workspace(WorkspaceID("one"))] != nil)

        let oldReduce = Motion.reduceMotionOverride
        let oldKinds = DesignSettings.shared.enabledAnimations
        DesignSettings.shared.enabledAnimations.insert(.newWorkspace)
        Motion.reduceMotionOverride = reduceMotion
        defer {
            Motion.reduceMotionOverride = oldReduce
            DesignSettings.shared.enabledAnimations = oldKinds
        }
        model.noteUserIntent()
        model.sections = Self.sections(.symbol("star", tint: nil))
        sidebar.list.reload(animated: true)
        let row = try #require(sidebar.list.rowViews[.workspace(WorkspaceID("two"))] as? WorkspaceRowView)
        let keys = Self.animations(under: row.icon.layer).compactMap { ($0 as? CAPropertyAnimation)?.keyPath }
        if reduceMotion {
            #expect(keys.isEmpty)
        } else {
            #expect(keys.contains("transform.scale"), "new workspace icon did not grow: \(keys)")
            #expect(keys.contains("opacity"), "new workspace icon did not fade: \(keys)")
            let scale = try #require(Self.animations(under: row.icon.layer).first {
                ($0 as? CAPropertyAnimation)?.keyPath == "transform.scale"
            })
            #expect(abs(scale.duration - Motion.sidebar.spring(SidebarInsertMotion.tunable.value.token).settlingTime(within: 0.002)) < 0.001)
        }
        #expect(row.icon.layer?.opacity == 1)
        #expect(row.icon.layer?.transform.m11 == 1)
        row.prepareForReuse(key: .workspace(WorkspaceID("reused")))
        #expect(Self.animations(under: row.icon.layer).isEmpty)
        #expect(row.icon.layer?.opacity == 1)
        #expect(row.icon.layer?.transform.m11 == 1)
    }

    @Test func reusingAnArchivedWorkspaceKeepsItsIconDimmed() {
        let key = SidebarRowKey.workspace(WorkspaceID("archived"))
        let row = WorkspaceRowView(key: key)
        row.icon.configure(icon: .symbol("star", tint: nil))
        row.icon.alphaValue = SidebarStyle.archivedAlpha
        row.prepareForReuse(key: key)
        #expect(abs((row.icon.layer?.opacity ?? 0) - Float(SidebarStyle.archivedAlpha)) < 0.001)
        #expect(row.icon.alphaValue == SidebarStyle.archivedAlpha)
    }

}
