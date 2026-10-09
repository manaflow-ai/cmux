import CmuxNextActions
import Foundation

/// cx-r3q: every cmux-next build crashes at the throw site of an
/// Objective-C exception AppKit would otherwise catch and log. On 2026-10-07
/// AppKit swallowed NSColor's getWhite exception, the unwind left Swift's
/// executor state corrupt, and the app died 60 ms later in the watchdog, so
/// the report blamed the wrong code. DEV and NIGHTLY first; Release and RC
/// too since 2026-10-08 (Lawrence via the chief: crashes stay visible at
/// their real cause, crash program phase 2). Registered at launch in the
/// volatile registration domain (never `defaults write`), so a user's own
/// setting still wins.
struct CrashOnExceptions {
    static let key = "NSApplicationCrashOnExceptions"

    /// The registration for a build: every channel crashes on exceptions.
    static func defaults(bundleID: String?, isDebugBuild: Bool) -> [String: Any] {
        [key: true]
    }

    /// Registers this process's choice; call before NSApplication exists.
    static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: Self.defaults(bundleID: Bundle.main.bundleIdentifier, isDebugBuild: DevTools.isDebugBuild))
    }
}
