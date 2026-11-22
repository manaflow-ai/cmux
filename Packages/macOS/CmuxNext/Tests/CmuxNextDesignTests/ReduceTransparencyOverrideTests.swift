import AppKit
import CmuxNextCompat
@testable import CmuxNextDesign
import Testing

/// A pinned Reduce Transparency (`debug.reduce_transparency`, Debug, tests) reaches the window
/// backdrops, not only the overlays: a capture on a host with the setting on (Blacksmith's macOS
/// VMs) pins it off and shows the window's translucency over its capture backdrop.
@MainActor
struct ReduceTransparencyOverrideTests {
    /// Changing the pin posts the display-options change on its center, which the window
    /// backdrops (`WindowRootView`, `WindowSurfaceView`) repaint on; setting the same value posts nothing.
    @Test func changingThePinPostsTheDisplayOptionsChange() {
        let center = NotificationCenter()
        let state = ReduceTransparency(system: { true }, changes: center)
        var posts = 0
        let observation = MainActorObservation(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, center: center,
                                               atOnce: true, read: { _ in () }) { posts += 1 }
        defer { observation.cancel() }
        state.override = false
        #expect(posts == 1)
        #expect(!state.isEnabled)
        state.override = false
        #expect(posts == 1)
        state.override = nil
        #expect(posts == 2)
        #expect(state.isEnabled)
    }

    /// A drag preview's backdrop follows the shared pin.
    @Test func aDragPreviewFollowsTheSharedPin() {
        let saved = ReduceTransparency.shared.override
        defer { ReduceTransparency.shared.override = saved }
        ReduceTransparency.shared.override = true
        #expect(WindowBackdrop.dragPreview(.app).isOpaque)
    }
}
