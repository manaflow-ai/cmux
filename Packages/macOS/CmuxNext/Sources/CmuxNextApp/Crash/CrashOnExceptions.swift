import CmuxNextActions
import Foundation

/// cx-r3q: DEV and NIGHTLY builds crash at the throw site of an Objective-C
/// exception AppKit would otherwise catch and log. On 2026-10-07 AppKit
/// swallowed NSColor's getWhite exception, the unwind left Swift's executor
/// state corrupt, and the app died 60 ms later in the watchdog, so the
/// report blamed the wrong code. Registered at launch in the volatile
/// registration domain (never `defaults write`), so a user's own setting
/// still wins; Release and RC keep AppKit's default for now.
struct CrashOnExceptions {
    static let key = "NSApplicationCrashOnExceptions"

    /// The registration for a build: DEV (a Debug compile) and NIGHTLY
    /// (`DevTools`) crash on exceptions; others register nothing.
    static func defaults(bundleID: String?, isDebugBuild: Bool) -> [String: Any] {
        DevTools.isAvailable(bundleID: bundleID, isDebugBuild: isDebugBuild) ? [key: true] : [:]
    }

    /// Registers this process's choice; call before NSApplication exists.
    static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: Self.defaults(bundleID: Bundle.main.bundleIdentifier, isDebugBuild: DevTools.isDebugBuild))
    }
}
