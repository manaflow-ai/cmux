import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// HOT PATH AUDIT frames (motion-frame): every pane overlay whose size changed in a layout spring frame stroked two
/// ring outlines (`ringOutline`: a rounded rect stroked into a path) for the focus glow's and the attention ring's
/// shadow paths, also when neither shows a shadow: the focus ring is off by default (no glow), and a pane with no unread
/// mark draws no attention ring. In Release that was 29 of 183 main-thread allocations per spring frame of a 12-pane
/// close (fleet job cc07848ba64e441c914fe3ec), the largest site of our own. A shadow path is now worked out only for a
/// layer that can show its shadow: the glow under the `glow` focus ring style, the attention ring while its glowing
/// mark or dismiss flash shows.
@MainActor @Suite(.serialized) struct RingOutlineShownOnlyTests {
    private func overlay(focusRing: FocusRingSettings = FocusRingSettings(), mark: AttentionMark? = nil) -> PaneOverlayView {
        _ = NSApplication.shared
        let view = PaneOverlayView()
        view.setFrameSize(NSSize(width: 400, height: 300))
        view.update(showsRing: true, dim: 0, focusRing: focusRing, border: PaneOverlayView.Border(shows: false),
                    attention: mark, attentionSettings: AttentionSettings(), readByEntry: false, animated: false)
        return view
    }

    /// 30 frames of a spring resize the overlay of a pane with the default settings (focus ring off, no mark).
    @Test func aResizingPaneWithNoShadowStrokesNoOutline() {
        let view = overlay()
        let before = view.ringOutlineBuilds
        for step in 1...30 { view.setFrameSize(NSSize(width: 400 - CGFloat(step), height: 300)) }
        let builds = view.ringOutlineBuilds - before
        print("HPA-COUNT case=ring-outline frames=30 builds=\(builds)")
        #expect(builds == 0, "30 resize frames stroked \(builds) ring outlines for shadows no one sees")
    }

    @Test func theGlowStyleKeepsItsShadowPathOnTheRing() throws {
        var glow = FocusRingSettings()
        glow.enabled = true
        glow.style = .glow
        let view = overlay(focusRing: glow)
        view.setFrameSize(NSSize(width: 360, height: 280))
        let path = try #require(view.glowShadowPath, "the glow lost its shadow path")
        #expect(path.boundingBoxOfPath.width <= 360 && path.boundingBoxOfPath.width > 350)
    }

    @Test func aGlowingMarkGetsItsShadowPathAndFollowsTheSize() throws {
        let view = overlay(mark: AttentionMark(generation: 3))
        view.setFrameSize(NSSize(width: 330, height: 280))
        let path = try #require(view.attentionLayer.shadowPath, "a glowing mark has no shadow path")
        #expect(path.boundingBoxOfPath.width <= 330 && path.boundingBoxOfPath.width > 320)
    }

    /// A pane resized while it had no mark gets a path at its current size when a mark arrives.
    @Test func aMarkArrivingAfterAResizeGetsThePathOfTheCurrentSize() throws {
        let view = overlay()
        view.setFrameSize(NSSize(width: 310, height: 250))
        view.update(showsRing: true, dim: 0, focusRing: FocusRingSettings(), border: PaneOverlayView.Border(shows: false),
                    attention: AttentionMark(generation: 4), attentionSettings: AttentionSettings(), readByEntry: false, animated: false)
        let path = try #require(view.attentionLayer.shadowPath)
        #expect(path.boundingBoxOfPath.width <= 310 && path.boundingBoxOfPath.width > 300)
    }
}
