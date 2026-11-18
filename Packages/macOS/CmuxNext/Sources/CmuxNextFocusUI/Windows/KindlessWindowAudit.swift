import AppKit
import os

/// Logs (a fault in debug builds, never a crash) the first time each
/// kind-less cmux window acts as the key window (plans/cmux-next/windows.md):
/// its owner must install it through the window kit. AppKit's own panels
/// (About, open and save, font, color), which no owner can install, are
/// logged at debug level only.
@MainActor
enum KindlessWindowAudit {
    private static let seen = NSHashTable<NSWindow>.weakObjects()
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.windows")

    static func note(_ window: NSWindow) {
        guard !seen.contains(window) else { return }
        seen.add(window)
        let name = String(describing: type(of: window))
        if Bundle(for: type(of: window)).bundlePath.hasPrefix("/System/") {
            logger.debug("system window without a kind is key: \(name, privacy: .public)")
            return
        }
        #if DEBUG
        logger.fault("window without a kind is key: \(name, privacy: .public)")
        #else
        logger.error("window without a kind is key: \(name, privacy: .public)")
        #endif
    }
}
