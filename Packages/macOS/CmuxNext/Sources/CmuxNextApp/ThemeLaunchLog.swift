import Foundation

/// Scratch: theme events as launch marks (sweep 4a), not for merge.
enum ThemeLaunchLog {
    nonisolated(unsafe) static var count = 0
    static func mark(_ event: String) {
        count += 1
        DebugTimings.markLaunch("theme.\(count) \(event)".replacingOccurrences(of: " ", with: "_"))
    }
}
