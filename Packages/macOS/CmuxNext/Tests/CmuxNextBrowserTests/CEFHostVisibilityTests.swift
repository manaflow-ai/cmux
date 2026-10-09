import AppKit
import Testing
@testable import CmuxNextBrowser

/// cx-asb1 slow tab switch: on a switch between two Chromium tabs of one
/// pane, the content lifecycle conceals the old tab before the new one is
/// presented. The shared host view was hidden and shown again in that one
/// call stack, so the fork ordered the whole page window out and in, and
/// Chromium handled a window hide and show instead of a tab switch (about
/// 100 ms late under load). The host view's visibility is derived state now,
/// applied once per run-loop turn: a same-pane switch never hides it, and a
/// conceal that no present follows hides it within the turn.
@MainActor
@Suite(.serialized) struct CEFHostVisibilityTests {
    private func rig() -> (CEFTab, CEFTab, NSWindow) {
        let runtime = CEFRuntime.shared
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: "hostvis"), profile: .default), runtime: runtime)
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        let second = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.add(second)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView!.addSubview(first.contentView)
        return (first, second, window)
    }

    /// Runs the main run loop for one short turn (deferred work runs there).
    private func turn() {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }

    @Test func aSamePaneSwitchNeverHidesTheHostView() {
        let (first, second, window) = rig()
        defer { window.close() }
        let host = first.host
        #expect(host.visibleTab === first && !host.hostView.isHidden)
        var states: [Bool] = []
        let watch = host.hostView.observe(\.isHidden, options: [.new]) { _, change in
            MainActor.assumeIsolated { states.append(change.newValue ?? false) }
        }
        defer { watch.invalidate() }
        // TabContentCache.apply: hides first, then shows; then the pane installs the new tab.
        first.setContentVisible(false)
        second.setContentVisible(true)
        first.contentView.removeFromSuperview()
        window.contentView!.addSubview(second.contentView)
        turn()
        #expect(host.visibleTab === second)
        #expect(!host.hostView.isHidden)
        #expect(!states.contains(true), "the page window never leaves the screen on a tab switch (states \(states))")
    }

    @Test func aConcealWithNoNewTabHidesTheHostViewWithinTheTurn() {
        let (first, _, window) = rig()
        defer { window.close() }
        let host = first.host
        first.setContentVisible(false)
        turn()
        #expect(host.hostView.isHidden, "a pane that shows no page any more hides it")
        first.setContentVisible(true)
        #expect(!host.hostView.isHidden, "showing is immediate")
    }

    /// An agent drives a tab its pane stopped showing: the tab's content view
    /// moves to the off-screen render window, which presents it there. The
    /// queued visibility pass of the pane's conceal must not undo that.
    @Test func aDrivenTabMovedToItsRenderWindowKeepsThePresentedState() {
        let (first, second, window) = rig()
        defer { window.close() }
        let host = first.host
        let panel = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 300), styleMask: [.borderless],
                             backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        // The pane shows another view; the agent's tab moves to its panel in the same turn.
        first.setContentVisible(false)
        first.contentView.removeFromSuperview()
        first.setContentVisible(true)
        panel.contentView!.addSubview(first.contentView)
        turn()
        #expect(host.visibleTab === first)
        #expect(host.hostView.superview === first.contentView, "the host view is in the driven tab's container")
        #expect(!host.hostView.isHidden, "the pass leaves the presented page shown")
        _ = second
    }
}
