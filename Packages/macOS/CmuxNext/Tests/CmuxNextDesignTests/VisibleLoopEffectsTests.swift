import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import SwiftUI
import Testing

/// SwiftUI's loops (`indeterminateSymbolEffect`, ``IndeterminateProgressBar``) run only while their
/// window shows (p14-energy-115): the probe behind them reports the window's visibility node, so an
/// occluded or miniaturized window, or a hidden view, stops the effect and a show starts it again.
@MainActor @Suite(.serialized) struct VisibleLoopEffectsTests {
    @Test func theProbeFollowsItsWindowsVisibility() throws {
        let host = LoopTestWindow(.visible)
        let shown = WindowShownProbe.Shown()
        let hosting = NSHostingView(rootView: WindowShownProbe(shown: shown).frame(width: 40, height: 20))
        host.window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        defer { host.window.contentView = nil }
        #expect(shown.isShown, "a probe in a shown window says its window does not show: the loop never runs")

        for state in [Visibility.occluded, .hidden] {
            host.set(state)
            #expect(!shown.isShown, "a probe in a \(state) window says it shows: the loop keeps running")
            host.set(.visible)
            #expect(shown.isShown, "the probe does not say shown again after its window was \(state)")
        }

        // A hidden ancestor (a hidden pane or section) stops it as well (recipe R-hide).
        hosting.isHidden = true
        #expect(!shown.isShown, "a probe in a hidden view says it shows")
        hosting.isHidden = false
        #expect(shown.isShown, "the probe does not say shown again when its view shows")

        // Out of its window, nobody sees it.
        host.window.contentView = nil
        #expect(!shown.isShown, "a probe out of its window says it shows")
    }
}
