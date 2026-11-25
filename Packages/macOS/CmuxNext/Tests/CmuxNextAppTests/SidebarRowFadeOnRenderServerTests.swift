import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import QuartzCore
import Testing

/// cmux-ad m23 F4 (STATUS 15571, oracle snap mode #36953): a new workspace row stayed transparent one refresh after its
/// slot opened, then faded in at 28-37 ms steps. The rows' frames spring on the render server from the change's
/// transaction, but the opening and closing rows' opacity ran on AppKit's animator (NSAnimationContext with a SwiftUI
/// spring), which NSAnimationManager drives from the main thread, starting at the next display-link tick. The fade must
/// be a Core Animation animation on the row's layer from the same apply, so it starts with the slot and needs no
/// main-thread frame; with motion off the row is opaque at once.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarRowFadeOnRenderServerTests {
    private static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    private static func key(_ id: Int) throws -> SidebarRowKey {
        .workspace(try #require(sections([id]).first?.workspaces.first?.id))
    }

    /// Workspaces `ids` in a window on screen, the first selected, new workspace rows opening on `motion`, Reduce Motion
    /// as `reduceMotion`. Returns the restore.
    private static func sidebar(_ ids: [Int], motion: SidebarInsertMotion, reduceMotion: Bool = false) throws
        -> (SidebarModel, SidebarListView, restore: () -> Void) {
        let start = sections(ids)
        let model = SidebarModel(sections: start, activeWorkspaceID: try #require(start.first?.workspaces.first?.id))
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 480)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        if window.screen == nil { window.close() }
        try #require(window.screen != nil)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.set(SidebarInsertMotion.tunable.key, .choice(motion.rawValue))
        let kinds = DesignSettings.shared.enabledAnimations
        DesignSettings.shared.enabledAnimations.insert(.newWorkspace)
        Motion.reduceMotionOverride = reduceMotion
        return (model, sidebar.list, {
            Motion.reduceMotionOverride = nil
            DesignSettings.shared.enabledAnimations = kinds
            TunableStore.shared.set(SidebarInsertMotion.tunable.key, nil)
            window.close()
        })
    }

    /// Cmd-N at the top, selected: in the same turn as the apply (before any display frame), the new row's layer holds a
    /// Core Animation opacity animation from 0 to 1, for the shipped snap motion and for the grow motion.
    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() },
          arguments: [SidebarInsertMotion.snap, .spring])
    func aNewRowFadesInOnTheRenderServerFromTheApply(_ motion: SidebarInsertMotion) throws {
        let ids = Array(1...10)
        let (model, list, restore) = try Self.sidebar(ids, motion: motion)
        defer { restore() }
        let next = Self.sections([100] + ids)
        model.sections = next
        if let id = next.first?.workspaces.first?.id { model.activeWorkspaceID = id }
        list.reload(animated: true)
        let view = try #require(list.rowViews[try Self.key(100)], "the new row has no view")
        let layer = try #require(view.layer)
        let fade = layer.animation(forKey: "opacity") as? CABasicAnimation
        #expect(fade != nil, "\(motion): the new row's fade is no Core Animation animation on its layer (animation keys: \(layer.animationKeys() ?? []))")
        #expect((fade?.fromValue as? NSNumber)?.floatValue == 0, "\(motion): the fade does not start transparent: \(String(describing: fade?.fromValue))")
        #expect((fade?.toValue as? NSNumber)?.floatValue == 1, "\(motion): the fade does not end opaque: \(String(describing: fade?.toValue))")
        #expect(view.alphaValue == 1, "\(motion): the model opacity is not the end value at once")
    }

    /// Close Workspace on the top row: in the same turn, the closing row's layer holds a Core Animation opacity animation
    /// to 0 while it shrinks.
    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() })
    func aClosingRowFadesOutOnTheRenderServerFromTheApply() throws {
        let ids = Array(1...10)
        let (model, list, restore) = try Self.sidebar(ids, motion: .snap)
        defer { restore() }
        let closing = try #require(list.rowViews[try Self.key(1)], "the first row has no view")
        let next = Self.sections(Array(ids.dropFirst()))
        model.sections = next
        if let id = next.first?.workspaces.first?.id { model.activeWorkspaceID = id }
        list.reload(animated: true)
        #expect(closing.closingEnd != nil, "the closed row does not close its slot")
        let fade = closing.layer?.animation(forKey: "opacity") as? CABasicAnimation
        #expect(fade != nil, "the closing row's fade is no Core Animation animation on its layer (animation keys: \(closing.layer?.animationKeys() ?? []))")
        #expect((fade?.toValue as? NSNumber)?.floatValue == 0, "the closing row's fade does not end transparent")
    }

    /// With motion off (Reduce Motion), a new row is opaque in the apply's own frame and nothing fades.
    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() })
    func withMotionOffANewRowIsOpaqueAtOnce() throws {
        let ids = Array(1...10)
        let (model, list, restore) = try Self.sidebar(ids, motion: .snap, reduceMotion: true)
        defer { restore() }
        let next = Self.sections([100] + ids)
        model.sections = next
        if let id = next.first?.workspaces.first?.id { model.activeWorkspaceID = id }
        list.reload(animated: true)
        let view = try #require(list.rowViews[try Self.key(100)], "the new row has no view")
        #expect(view.alphaValue == 1, "with motion off the new row is not opaque at once")
        #expect(view.layer?.animation(forKey: "opacity") == nil, "with motion off the new row still fades")
    }
}
