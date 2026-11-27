#if DEBUG
import AppKit

/// Chooses the visible cmux window targeted by the debug screenshot command.
enum WindowScreenshotWindowSelector {
    @MainActor
    static func select(
        eligibleWindows: [NSWindow],
        keyWindow: NSWindow?,
        mainWindow: NSWindow?,
        terminalWindow: NSWindow?
    ) -> NSWindow? {
        let preferredWindows = [keyWindow, mainWindow, terminalWindow]
            .compactMap { $0 }
        if let preferred = preferredWindows.first(where: { preferred in
            eligibleWindows.contains(where: { $0 === preferred })
        }) {
            return preferred
        }

        return eligibleWindows.max { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }
    }
}
#endif
