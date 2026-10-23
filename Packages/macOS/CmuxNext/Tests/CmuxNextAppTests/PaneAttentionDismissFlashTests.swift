import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// A pane's attention ring appears steady when its notification arrives and blinks out when the
/// person goes into the pane and reads it, as in cmux classic (Austin, 2026-10-20). A ring cleared
/// any other way (Mark Read from the sidebar, a timeout, a mute, another device) just fades.
@MainActor @Suite(.serialized)
struct PaneAttentionDismissFlashTests {
    private static func overlay(marked: Bool) -> PaneOverlayView {
        let view = PaneOverlayView()
        view.setFrameSize(NSSize(width: 400, height: 300))
        update(view, mark: marked ? AttentionMark(generation: 7) : nil, readByEntry: false)
        return view
    }

    private static func update(_ view: PaneOverlayView, mark: AttentionMark?, readByEntry: Bool) {
        view.update(showsRing: false, dim: 0, focusRing: FocusRingSettings(), border: PaneOverlayView.Border(shows: false),
                    attention: mark, attentionSettings: AttentionSettings(), readByEntry: readByEntry, animated: true)
    }

    @Test func aNewNotificationShowsASteadyRing() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let view = Self.overlay(marked: true)
        #expect(view.attentionOpacity > 0, "no ring for the notification")
        #expect(!view.attentionAnimationKeys.contains("attention-dismiss"))
    }

    @Test func goingIntoThePaneBlinksTheRingOut() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let view = Self.overlay(marked: true)
        Self.update(view, mark: nil, readByEntry: true)
        #expect(view.attentionAnimationKeys.contains("attention-dismiss"), "the ring went away without its flash")
        #expect(view.attentionOpacity == 0, "the ring stays after the flash")
    }

    @Test func aRingClearedAnyOtherWayFadesWithoutAFlash() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let view = Self.overlay(marked: true)
        Self.update(view, mark: nil, readByEntry: false)
        #expect(!view.attentionAnimationKeys.contains("attention-dismiss"))
        #expect(view.attentionOpacity == 0)
    }
}
