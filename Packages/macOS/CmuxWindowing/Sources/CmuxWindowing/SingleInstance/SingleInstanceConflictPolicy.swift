public import Foundation

/// What a launching cmux does about another running process with its bundle id.
///
/// The newest launch used to force-terminate every older instance. When the
/// newcomer is a different bundle that shares the id (a locally built Release
/// app, a copy in Downloads, a tool launching a build under a profiler), that
/// killed the user's running app and its live agent sessions without a final
/// session save (incident 2026-09-26). Now only a relaunch of the same bundle
/// replaces the running one; any other bundle yields to it.
public enum SingleInstanceConflictPolicy {
    public enum Action: Equatable, Sendable {
        /// The same bundle relaunched itself: ask the older instance to quit.
        case replaceExisting
        /// A different bundle: leave the running app alone and exit.
        case yieldToExisting
    }

    /// Environment variable that restores the replace-anything behavior for a
    /// deliberate swap, e.g. `CMUX_ALLOW_REPLACING_RUNNING_CMUX=1`.
    public static let allowReplacingEnvironmentKey = "CMUX_ALLOW_REPLACING_RUNNING_CMUX"

    /// Seconds a replaced instance gets to quit (and save its session)
    /// before it is force-terminated.
    public static let gracefulTerminationTimeout: TimeInterval = 10

    public static func action(
        currentBundleURL: URL,
        existingBundleURL: URL?,
        environment: [String: String]
    ) -> Action {
        if environment[allowReplacingEnvironmentKey] == "1" { return .replaceExisting }
        guard let existingBundleURL else { return .yieldToExisting }
        return canonical(currentBundleURL) == canonical(existingBundleURL) ? .replaceExisting : .yieldToExisting
    }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
