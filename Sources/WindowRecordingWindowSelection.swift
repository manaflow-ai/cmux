import AppKit
import CoreGraphics

/// Picks the cmux window a recording films, and validates its identifier.
///
/// The same preference order as the debug screenshot command's
/// `WindowScreenshotWindowSelector`, kept separate because that one is a
/// DEBUG-only type and recording ships in Release. Nothing here captures
/// anything; it only chooses a window that is on screen and big enough to be
/// worth filming.
enum WindowRecordingWindowSelection {
    @MainActor
    static func eligibleWindows(in application: NSApplication) -> [NSWindow] {
        application.windows.filter { window in
            window.isVisible &&
                !window.isMiniaturized &&
                window.contentView != nil &&
                !window.frame.isEmpty
        }
    }

    @MainActor
    static func select(
        eligibleWindows: [NSWindow],
        keyWindow: NSWindow?,
        mainWindow: NSWindow?,
        terminalWindow: NSWindow?
    ) -> NSWindow? {
        let preferred = [keyWindow, mainWindow, terminalWindow].compactMap { $0 }
        if let match = preferred.first(where: { candidate in
            eligibleWindows.contains(where: { $0 === candidate })
        }) {
            return match
        }
        return eligibleWindows.max { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }
    }

    /// ScreenCaptureKit takes an unsigned window id; AppKit hands out a signed
    /// window number, and a negative one belongs to no capturable window.
    static func windowID(fromWindowNumber windowNumber: Int) -> CGWindowID? {
        CGWindowID(exactly: windowNumber)
    }
}
