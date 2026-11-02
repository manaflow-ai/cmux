import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextLayout
import Testing

/// REOPEN-F2 (reopen film, cmux24, 2026-11-02): after Cmd-Q (keep sessions) and reopen, the window came in
/// with AppKit's document-window zoom (about 3 frames, its content scaled by a few pixels). The main window
/// never set `animationBehavior`, so AppKit's default open animation ran outside every motion gate. A window
/// the launch restores shows in place, in its first frame, with no animation at all.
@MainActor @Suite(.serialized, .closesItsWindows) struct RestoredWindowOpensInPlaceTests {
    @Test func theLaunchWindowOpensWithNoAnimation() throws {
        _ = NSApplication.shared
        // Motion on: the window opens in place because the launch restores it, not because animations are off.
        let previous = Motion.reduceMotionOverride
        defer { Motion.reduceMotionOverride = previous }
        Motion.reduceMotionOverride = false
        try #require(Motion.panes.animatesMovement, "motion is off on this host: the test would not prove the restore rule")
        let services = AppServices(environment: AppEnvironment.current([:]))
        // The launch, before its restore ended (the launch snapshot's window, `restoreWhenLoaded`).
        services.windows.registry.isLaunching = true
        let controller = services.windows.makeController(for: WindowRegistry.Window(id: "restored-in-place"))
        defer { controller.teardown(); controller.window?.close() }
        #expect(controller.window?.animationBehavior == NSWindow.AnimationBehavior.none,
                "a restored window zooms in (AppKit's default open animation) instead of showing in place")
    }
}
