import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing
import CmuxNextFocus

/// Leo 2026-10-14: "after splitting there's some weird focus-ish rings, not the colored ones,
/// just some gray stuff that kinda straggles behind". The split's daemon tree mounted the new
/// pane and drew the gray focus ring around the old one at its new, narrower frame; the focus
/// coordinator moved focus to the new pane in the same apply, but the layout view mirrored that
/// only on its observation's next turn, so the old pane's ring stayed for frames, vanished, and
/// the ring faded in on the new pane. The ring now follows the focus in the apply that lands it.
@Suite(.closesItsWindows)
@MainActor struct SplitFocusRingTests {
    private static func tree(split: Bool) -> DaemonTree {
        let first = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let second = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")])
        let layout: LayoutNode = split
            ? .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first.id), b: .leaf(second.id))
            : .leaf(first.id)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: split ? [first, second] : [first])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"split-focus-ring-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// The window's focus effects on the layout: a pane the focus lands on is the layout's
    /// focused pane (`FocusEffectApplier`'s `revealPane`). Responder and context effects need a
    /// window controller and do not move the ring.
    final class LayoutFocusApplier: FocusEffectApplying {
        weak var content: WorkspaceContentController?
        func apply(_ effects: [FocusEffect], state: FocusState) {
            for case let .revealPane(pane) in effects {
                content?.layoutModel.focus(LayoutPaneID(pane), notify: false)
            }
        }
    }

    @Test func theRingMovesToTheSplitsNewPaneInTheApplyThatMountsIt() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        // The ring marks focus only with `appearance.focusIndicator` border or both (the default is tabs)
        // and with `focusRing.enabled` on: focus outlines are opt-in since #23745 (the default is off).
        let indicator = DesignSettings.shared.focusIndicator
        let ring = DesignSettings.shared.focusRing
        DesignSettings.shared.focusIndicator = .both
        DesignSettings.shared.focusRing.enabled = true
        defer {
            DesignSettings.shared.focusIndicator = indicator
            DesignSettings.shared.focusRing = ring
        }
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree(split: false))
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let applier = LayoutFocusApplier()
        state.focus.applier = applier
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        applier.content = content
        defer { content.teardown() }
        content.contentView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        window.contentView = content.contentView
        window.orderFrontRegardless()
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        let old = try #require(content.layoutModel.screens.first?.layout.panes.first)

        // Cmd-D: the split asks for focus on its new terminal before the pane lands
        // (PaneHandlers.split), then the daemon's tree mounts it.
        content.expectFocus(on: SurfaceID(rawValue: 2))
        store.apply(snapshot: Self.tree(split: true))
        content.applyCurrent()

        let panes = try #require(content.layoutModel.screens.first?.layout.panes)
        let new = try #require(panes.first { $0 != old })
        #expect(content.layoutModel.focusedPane == new, "the split's new pane did not take focus")
        // What the frame committed now shows, before any observation turn.
        let rings = content.layoutView.overlayRings
        #expect(rings.count == 2, "\(rings.count) pane overlays for 2 panes")
        #expect(rings.first { $0.pane == old.rawValue }?.showsRing == false,
                "the old pane kept the focus ring at its new frame after the split: \(rings)")
        #expect(rings.first { $0.pane == new.rawValue }?.showsRing == true, "the new pane has no focus ring: \(rings)")
        // Every overlay is on its pane's current frame: nothing is left where the pane was.
        #expect(rings.allSatisfy { $0.ringInSync }, "a ring is off its pane's content: \(rings)")
    }
}
