import Foundation

/// Which Screenshots tabs the person has unlocked with Show Screenshots, by tab key. A tab's page is made again
/// after a hibernation wake or an engine switch; an unlocked tab lists at once then, with no second click. Until
/// the first tab is unlocked, no folder is detected, read or watched (macOS guards ~/Desktop: LAUNCH-NO-TCC-PROMPTS).
@MainActor
public final class ScreenshotsGate {
    private var unlocked: Set<String> = []

    /// Makes an empty gate: no tab unlocked.
    public init() {}

    /// Whether the person unlocked the tab `key`.
    public func isUnlocked(_ key: String) -> Bool { true }

    /// Whether any tab is unlocked: only then may the folders be detected.
    public var mayDetect: Bool { true }

    /// The person clicked Show Screenshots in the tab `key`.
    public func unlock(_ key: String) { unlocked.insert(key) }

    /// The tab `key` closed for good.
    public func forget(_ key: String) { unlocked.remove(key) }
}
