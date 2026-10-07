import AppKit
import CmuxNextDesign
import Foundation
import Testing

/// Whether the window server gives this test process an image of its own
/// window (`NSWindow.compositedSnapshot`, `CGWindowListCreateImage`): the
/// capability that `debug.window_snapshot`'s composited path and its child
/// window layers need.
///
/// A GUI session is not enough. The glaeda CI minis have a console session
/// and a screen (`.requiresGUISession` tests run there, and
/// `CMUX_TEST_REQUIRE_GUI=1` makes them required), but no lit display: the
/// window server gives no image of the process's windows, so the snapshot
/// falls back to AppKit drawing without child windows (cmux-next run
/// 37613518221: `method` "appkit", `child_windows` 0, the child's pixel
/// gray). cmux-lawrence-2 (a lit display) gives the image. So the check
/// asks the window server directly: a small opaque window of this process
/// goes on screen, and the check passes when the window server returns a
/// non-blank image of it within 3 s (the same wait the snapshot fixtures
/// use for a new window).
@MainActor
enum WindowServerImages {
    private static var probed: Bool?

    static var areAvailable: Bool {
        if let probed { return probed }
        let result = probe()
        probed = result
        return result
    }

    private static func probe() -> Bool {
        _ = NSApplication.shared
        guard let screen = NSScreen.main?.visibleFrame else { return false }
        let window = NSWindow(contentRect: NSRect(x: screen.minX + 40, y: screen.minY + 40, width: 64, height: 64),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        window.isOpaque = true
        window.orderFrontRegardless()
        window.displayIfNeeded()
        defer { window.close() }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if window.compositedSnapshot() != nil { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }
}

extension Trait where Self == ConditionTrait {
    /// The test needs window server images of its own windows. Not forced by
    /// `CMUX_TEST_REQUIRE_GUI`: the GUI minis lack this capability, and the
    /// `.lacksWindowServerImages` tests cover the snapshot there.
    static var requiresWindowServerImages: Self {
        .enabled("needs window server images of this process's windows (none on a host without a lit display)") {
            await WindowServerImages.areAvailable
        }
    }

    /// The test covers a host where the window server gives no image of this
    /// process's windows; a host that gives one runs the
    /// `.requiresWindowServerImages` tests instead.
    static var lacksWindowServerImages: Self {
        .disabled("the window server gives images of this process's windows here; the composited tests run instead") {
            await WindowServerImages.areAvailable
        }
    }
}
