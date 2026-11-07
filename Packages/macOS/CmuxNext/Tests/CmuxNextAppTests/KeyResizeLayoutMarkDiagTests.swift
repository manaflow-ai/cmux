import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Observation
import Testing

/// RESIZE P0 5 diagnostic (no merge): which part of `LayoutRootView.layout()` reads model state that a key press changes
/// (AppKit's observation tracking of `layout()` marks the root when a read value changes).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct KeyResizeLayoutMarkDiagTests {
    typealias Ground = PaneGroundCoversPaneTests

    nonisolated(unsafe) static var fired: [String] = []

    @Test func whichLayoutReadTheKeyChanges() throws {
        let rig = Ground.Rig(Ground.column(Ground.pair), focused: "p2")
        defer { rig.close() }
        rig.root.layoutSubtreeIfNeeded()
        rig.commit()
        Self.fired = []
        let root = rig.root
        func track(_ name: String, _ body: () -> Void) {
            withObservationTracking(body) { KeyResizeLayoutMarkDiagTests.fired.append(name) }
        }
        track("layout (all)") { root.layout() }
        track("applyScreenFrames") { root.applyScreenFrames() }
        track("updateVisibility") { root.updateVisibility() }
        track("overlayPlane.syncFrame") { _ = root.overlayPlane.syncFrame() }
        track("syncOverlay (stale)") { root.overlayIsStale = true; root.flushOverlaySync() }
        track("planeHost.planeDidLayout") { root.planeHost?.planeDidLayout(root.overlayPlane) }
        for (id, view) in root.screenViews {
            track("screen \(id) visiblePanes") { _ = view.visiblePanes() }
            track("screen \(id) keepAlivePanes") { _ = view.keepAlivePanes() }
        }
        track("model.activeScreenID") { _ = rig.model.activeScreenID }
        track("model.focusedPane") { _ = rig.model.focusedPane }
        #expect(PaneResize.press("p2", .right, model: rig.model, view: root))
        Issue.record("DIAG fired after press: \(Self.fired); planeHost \(root.planeHost == nil ? "nil" : "set")")
    }
}
