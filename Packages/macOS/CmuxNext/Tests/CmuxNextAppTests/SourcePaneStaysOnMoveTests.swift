import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextControl
@testable import CmuxNextDaemon
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo, 2026-11-22: "when i click on an unloaded tab of anything at all the whole pane re-renders still on this version"
/// and "likewise when i move one tab completely to another pane, the original pane flickers a re-render".
///
/// The layout-motion scenario: each step runs the app's own pieces (a `WorkspaceContentController` on an offline store,
/// its `PaneController`s, the content cache that keys every tab's view by the tab's own id and reparents it on a move)
/// and reads the **source pane** in the step's own turn and in every display frame after it until rest:
/// - view creations: views mounted under the source pane's host that were not there before, other than the content of
///   the tab the pane now selects (the only thing a step may make), plus a new controller or host for the pane;
/// - frame changes: frames where the source pane's host moved or resized while it stays in the layout, or where it
///   showed its ground (no tab's view) where a tab's view should be.
/// Both are 0 for every step. Each step's milliseconds (turn plus frames to rest) are printed as one
/// `layout-motion:` line, the numbers of the before/after table.
///
/// Deterministic as `PaneCommitMotionTests+Drop`: the test is the layout's clock (`DisplayLinkDriver.isManual`) and the
/// presentation's (``ContentPresentationScheduler/frames``).
@Suite(.serialized, .closesItsWindows)
@MainActor struct SourcePaneStaysOnMoveTests {
    nonisolated enum Step: String, CaseIterable, CustomTestStringConvertible, Sendable {
        /// p1 [moved, an unloaded terminal] beside p2 [terminal]: the shown tab moves into p2; p1 keeps its other tab.
        case moveKeepsTabs = "move a tab to another pane, the pane keeps its other tabs"
        /// p1 [moved] beside p2 [terminal]: the only tab moves into p2; p1 leaves the layout.
        case moveLeavesEmpty = "move a tab to another pane, the pane is left empty"
        /// p1 [shown terminal, an unloaded terminal]: a click on the unloaded one.
        case clickUnloaded = "click an unloaded tab"
        var testDescription: String { rawValue }
    }

    @Test(arguments: Step.allCases)
    func theSourcePaneMakesNoViewAndMovesNoFrame(_ step: Step) throws {
        let rig = try SourcePaneRig(step)
        defer { rig.close() }
        let before = rig.reading()
        let started = ContinuousClock.now
        rig.act()
        var readings = [rig.reading()]
        rig.drop.commit()
        var frame = 0, moving = true
        while frame < 240, moving || frame < 3 {
            frame += 1
            moving = rig.drop.step()
            readings.append(rig.reading())
            rig.drop.commit()
        }
        let elapsed = ContinuousClock.now - started
        try #require(!moving, "the step's frames did not end in 2 s")
        try #require(rig.landed(), "SETUP: the step did not land: \(rig.describe())")

        let created = rig.creations(since: before, in: readings)
        let changes = rig.frameChanges(from: before, in: readings)
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print("layout-motion: step=\(step) view_creations=\(created.count) frame_changes=\(changes.count) frames=\(frame) ms=\(String(format: "%.1f", ms))")
        #expect(created.isEmpty, "\(step): the source pane made \(created.count) view(s): \(created.prefix(6))")
        #expect(changes.isEmpty, "\(step): the source pane changed in \(changes.count) frame(s): \(changes.prefix(4))")
    }
}

/// One window of the app at rest, ready for one step of the layout-motion scenario, and the source pane's readings.
@MainActor
final class SourcePaneRig {
    typealias Step = SourcePaneStaysOnMoveTests.Step

    /// What the source pane is in one frame.
    struct Reading {
        var controller: ObjectIdentifier?
        var host: ObjectIdentifier?
        var hostFrame: String?
        var inLayout: Bool
        var showsGround: Bool
        var views: [ObjectIdentifier: String]
        var selectedContent: Set<ObjectIdentifier>
    }

    let step: Step
    let drop: Rig
    let source: LayoutPaneID
    let movedKey: String, otherKey: String?

    /// The rig of `PaneCommitMotionTests+Drop` with this scenario's trees.
    @MainActor final class Rig {
        let services: AppServices
        let state: WindowState
        let window: NSWindow
        let content: WorkspaceContentController
        let frames = PaneDropRig.Frames()
        private var committed: [@MainActor () -> Void] = []
        var root: LayoutRootView { content.layoutView }

        init(_ tree: DaemonTree) throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            services.presentation.frames = frames
            services.launchReveal.markAllReady()
            let store = services.daemon.store
            let identity = DaemonIdentity(capabilities: [DaemonCapability.dockColumns.rawValue], generation: DaemonGeneration(rawValue: "source-pane"))
            store.noteHandshake(identity)
            store.connectionState = .connected(identity)
            store.apply(snapshot: tree)
            let workspace = try #require(store.workspaces.first)
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"source-pane","workspace_key":"w1"}"#.utf8))
            state = WindowState(record: record)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
            content.contentView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
            window.contentView = content.contentView
            window.orderFrontRegardless()
            root.context.reduceMotionOverride = false
            root.context.commitMotionOverride = true
            root.context.afterCommit = { [weak self] in self?.committed.append($0) }
            root.driver.isManual = true
            root.driver.detach()
            root.driver.attach(to: root)
            content.applyCurrent()
            content.contentView.layoutSubtreeIfNeeded()
            for pane in content.panes.values {
                pane.syncStripFromStore()
                pane.showSelected()
            }
            settle()
        }

        func settle() {
            var settling = 0
            while settling < 240, step() || settling < 3 {
                commit()
                settling += 1
            }
            commit()
        }

        @discardableResult
        func step() -> Bool {
            let presentation = frames.hasPending
            frames.fire()
            let asks = root.advanceFrame(PaneDropRig.dt)
            content.contentView.layoutSubtreeIfNeeded()
            return asks || presentation || frames.hasPending
        }

        func commit() {
            while !committed.isEmpty {
                let work = committed
                committed = []
                for item in work { item() }
            }
        }

        func close() {
            withExtendedLifetime((services, state)) {
                content.teardown()
                window.closeAfterTest()
            }
        }
    }

    static let moved = CmuxNextDaemon.SurfaceID(rawValue: 1), neighbor = CmuxNextDaemon.SurfaceID(rawValue: 2)
    static let other = CmuxNextDaemon.SurfaceID(rawValue: 3)
    static func pane(_ id: UInt64) -> CmuxNextDaemon.PaneID { CmuxNextDaemon.PaneID(rawValue: id) }

    /// The daemon's tree before the step or after it.
    static func tree(_ step: Step, after: Bool) -> DaemonTree {
        let moved = TabSnapshot(surface: moved, title: "moved"), neighbor = TabSnapshot(surface: neighbor, title: "neighbor")
        let other = TabSnapshot(surface: other, title: "unloaded")
        let split = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(pane(1)), b: .leaf(pane(2)))
        let panes: [PaneSnapshot], layout: LayoutNode
        switch (step, after) {
        case (.moveKeepsTabs, false), (.clickUnloaded, _):
            (panes, layout) = ([PaneSnapshot(id: pane(1), tabs: [moved, other]), PaneSnapshot(id: pane(2), tabs: [neighbor])], split)
        case (.moveKeepsTabs, true):
            (panes, layout) = ([PaneSnapshot(id: pane(1), tabs: [other]), PaneSnapshot(id: pane(2), tabs: [neighbor, moved])], split)
        case (.moveLeavesEmpty, false):
            (panes, layout) = ([PaneSnapshot(id: pane(1), tabs: [moved]), PaneSnapshot(id: pane(2), tabs: [neighbor])], split)
        case (.moveLeavesEmpty, true):
            (panes, layout) = ([PaneSnapshot(id: pane(2), tabs: [neighbor, moved])], .leaf(pane(2)))
        }
        let column = ColumnSnapshot(id: CmuxNextDaemon.ColumnID(rawValue: 10), width: 1, layout: layout, dock: nil)
        let screen = ScreenSnapshot(id: 1, layout: layout, columns: [column], panes: panes)
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }

    init(_ step: Step) throws {
        self.step = step
        drop = try Rig(Self.tree(step, after: false))
        let store = drop.services.daemon.store
        movedKey = try #require(store.tab(surface: Self.moved)?.id, "SETUP: no moved tab")
        otherKey = store.tab(surface: Self.other)?.id
        let pane = try #require(drop.content.panes.values.first { $0.pane.handle == Self.pane(1) }, "SETUP: no source pane")
        source = pane.layoutPaneID
        pane.applySelection(StripTabID(movedKey))
        drop.settle()
        try #require(pane.currentTabKey == movedKey && pane.view.hostsContent, "SETUP: the source pane does not show its tab")
        if let otherKey { try #require(drop.services.cache.existingTerminal(otherKey) == nil, "SETUP: the unloaded tab has a surface") }
    }

    /// The step's one turn, as the app takes it: the daemon's tree after a move, applied as the store's observation applies
    /// it, the destination selecting the tab it took; or the click's selection.
    func act() {
        switch step {
        case .moveKeepsTabs, .moveLeavesEmpty:
            drop.services.daemon.store.apply(snapshot: Self.tree(step, after: true))
            drop.content.applyCurrent()
            target?.applySelection(StripTabID(movedKey))
        case .clickUnloaded:
            if let otherKey { sourcePane?.applySelection(StripTabID(otherKey)) }
        }
    }

    var sourcePane: PaneController? { drop.content.panes[source] }
    var target: PaneController? { drop.content.panes.values.first { $0.pane.handle == Self.pane(2) } }

    func landed() -> Bool {
        switch step {
        case .moveKeepsTabs: return target?.currentTabKey == movedKey && sourcePane?.currentTabKey == otherKey
        case .moveLeavesEmpty: return target?.currentTabKey == movedKey && sourcePane == nil
        case .clickUnloaded: return sourcePane?.currentTabKey == otherKey
        }
    }

    func describe() -> String {
        "source shows \(sourcePane?.currentTabKey ?? "nothing (gone)"), target shows \(target?.currentTabKey ?? "nothing")"
    }

    private var sourceHost: PaneHostView? {
        for screen in drop.root.screenViews.values where !screen.isHidden {
            for case let host as PaneHostView in screen.subviews where host.pane == source { return host }
        }
        return nil
    }

    func reading() -> Reading {
        let host = sourceHost, pane = sourcePane
        var views: [ObjectIdentifier: String] = [:]
        func walk(_ view: NSView) {
            views[ObjectIdentifier(view)] = String(describing: type(of: view))
            view.subviews.forEach(walk)
        }
        if let host { walk(host) }
        var selected: Set<ObjectIdentifier> = []
        func mark(_ view: NSView) {
            selected.insert(ObjectIdentifier(view))
            view.subviews.forEach(mark)
        }
        // The content of the tab the pane now selects is the one thing a step may make in it.
        let newTab = step == .clickUnloaded || step == .moveKeepsTabs ? otherKey : nil
        if let pane, let newTab, pane.currentTabKey == newTab, let view = pane.currentContent?.view { mark(view) }
        let shows = host.map(PaneDropRig.shows) ?? false
        let ground: Bool
        if let pane {
            ground = shows && !pane.view.hostsContent
        } else {
            ground = shows && (host?.content as? PaneContentView)?.hostsContent != true
        }
        return Reading(controller: pane.map(ObjectIdentifier.init), host: host.map(ObjectIdentifier.init),
                       hostFrame: host.map { "\($0.frame) layer \($0.layer?.frame ?? .zero)" },
                       inLayout: pane != nil, showsGround: ground, views: views, selectedContent: selected)
    }

    /// Views under the source pane's host that were not there before, other than the selected tab's content; a new
    /// controller or host counts as one.
    func creations(since before: Reading, in readings: [Reading]) -> [String] {
        var seen = Set(before.views.keys), made: [String] = []
        for (index, now) in readings.enumerated() {
            if let controller = now.controller, controller != before.controller { made.append("frame \(index): a new PaneController") }
            if let host = now.host, host != before.host { made.append("frame \(index): a new PaneHostView") }
            for (id, kind) in now.views where !seen.contains(id) && !now.selectedContent.contains(id) {
                made.append("frame \(index): \(kind)")
            }
            seen.formUnion(now.views.keys)
        }
        return made
    }

    /// Frames where the source pane's host moved while it stays in the layout, or showed its ground.
    func frameChanges(from before: Reading, in readings: [Reading]) -> [String] {
        var changes: [String] = []
        for (index, now) in readings.enumerated() {
            if now.showsGround { changes.append("frame \(index): shows its ground") }
            if now.inLayout, let frame = now.hostFrame, frame != before.hostFrame {
                changes.append("frame \(index): host \(frame), was \(before.hostFrame ?? "none")")
            }
        }
        return changes
    }

    func close() { drop.close() }
}
