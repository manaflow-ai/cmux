import Foundation
import Testing
import Bonsplit
@testable import CmuxPanes

/// Unit tests for `ExternalTreeNode.combineLayoutFingerprint(into:)`, the
/// layout-shape hash the session autosave fingerprint folds in so that a pure
/// pane/surface reorder is re-persisted instead of lost on a non-graceful exit
/// (https://github.com/manaflow-ai/cmux/issues/6184).
@Suite struct LayoutFingerprintTests {
    private func fingerprint(_ node: ExternalTreeNode) -> Int {
        var hasher = Hasher()
        node.combineLayoutFingerprint(into: &hasher)
        return hasher.finalize()
    }

    private func pane(
        _ id: String,
        tabs: [String],
        selected: String? = nil,
        titlePrefix: String = "title"
    ) -> ExternalTreeNode {
        .pane(ExternalPaneNode(
            id: id,
            frame: PixelRect(x: 0, y: 0, width: 100, height: 100),
            tabs: tabs.map { ExternalTab(id: $0, title: "\(titlePrefix)-\($0)") },
            selectedTabId: selected
        ))
    }

    private func split(
        _ first: ExternalTreeNode,
        _ second: ExternalTreeNode,
        orientation: String = "horizontal",
        divider: Double = 0.5
    ) -> ExternalTreeNode {
        .split(ExternalSplitNode(
            id: "s",
            orientation: orientation,
            dividerPosition: divider,
            first: first,
            second: second
        ))
    }

    @Test func reorderingSurfacesWithinAPaneChangesFingerprint() {
        let original = pane("p", tabs: ["t1", "t2", "t3"])
        let reordered = pane("p", tabs: ["t2", "t1", "t3"])
        #expect(fingerprint(original) != fingerprint(reordered))
    }

    @Test func swappingPanePositionsChangesFingerprint() {
        let left = pane("a", tabs: ["t1"])
        let right = pane("b", tabs: ["t2"])
        #expect(fingerprint(split(left, right)) != fingerprint(split(right, left)))
    }

    @Test func changingSplitOrientationChangesFingerprint() {
        let left = pane("a", tabs: ["t1"])
        let right = pane("b", tabs: ["t2"])
        #expect(
            fingerprint(split(left, right, orientation: "horizontal"))
                != fingerprint(split(left, right, orientation: "vertical"))
        )
    }

    @Test func changingSelectedSurfaceChangesFingerprint() {
        #expect(
            fingerprint(pane("p", tabs: ["t1", "t2"], selected: "t1"))
                != fingerprint(pane("p", tabs: ["t1", "t2"], selected: "t2"))
        )
    }

    @Test func addingASurfaceChangesFingerprint() {
        #expect(fingerprint(pane("p", tabs: ["t1"])) != fingerprint(pane("p", tabs: ["t1", "t2"])))
    }

    @Test func identicalLayoutsHashEqual() {
        let lhs = split(
            pane("a", tabs: ["t1", "t2"], selected: "t1"),
            pane("b", tabs: ["t3"]),
            orientation: "vertical",
            divider: 0.4
        )
        let rhs = split(
            pane("a", tabs: ["t1", "t2"], selected: "t1"),
            pane("b", tabs: ["t3"]),
            orientation: "vertical",
            divider: 0.4
        )
        #expect(fingerprint(lhs) == fingerprint(rhs))
    }

    @Test func dividerResizeChangesFingerprintButJitterDoesNot() {
        let left = pane("a", tabs: ["t1"])
        let right = pane("b", tabs: ["t2"])
        // A real resize (10%) changes it.
        #expect(fingerprint(split(left, right, divider: 0.5)) != fingerprint(split(left, right, divider: 0.6)))
        // Sub-0.1% jitter rounds to the same bucket and does not.
        #expect(fingerprint(split(left, right, divider: 0.5)) == fingerprint(split(left, right, divider: 0.50004)))
    }

    @Test func surfaceTitleDoesNotAffectFingerprint() {
        // Titles are hashed elsewhere in the autosave fingerprint; the layout
        // hash only cares about identity/order.
        #expect(
            fingerprint(pane("p", tabs: ["t1", "t2"], titlePrefix: "alpha"))
                == fingerprint(pane("p", tabs: ["t1", "t2"], titlePrefix: "omega"))
        )
    }

    @Test func paneFrameDoesNotAffectFingerprint() {
        // Frames are recomputed on restore; only divider fractions are persisted.
        let a = ExternalTreeNode.pane(ExternalPaneNode(
            id: "p",
            frame: PixelRect(x: 0, y: 0, width: 100, height: 100),
            tabs: [ExternalTab(id: "t1", title: "t")],
            selectedTabId: nil
        ))
        let b = ExternalTreeNode.pane(ExternalPaneNode(
            id: "p",
            frame: PixelRect(x: 7, y: 9, width: 640, height: 480),
            tabs: [ExternalTab(id: "t1", title: "t")],
            selectedTabId: nil
        ))
        #expect(fingerprint(a) == fingerprint(b))
    }
}
