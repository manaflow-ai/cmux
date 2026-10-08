public import Foundation

/// What a launching cmux does about another running process with its bundle id.
///
/// The newest launch used to force-terminate every older instance. When the
/// newcomer is a different bundle that shares the id (a locally built Release
/// app, a copy in Downloads, a tool launching a build under a profiler), that
/// killed the user's running app and its live agent sessions without a final
/// session save (incident 2026-09-26). Ordinary launches now yield to an
/// existing instance, including a relaunch of the same bundle. Deliberate
/// reload tooling must opt into replacement explicitly.
public struct SingleInstanceConflictPolicy: Sendable {
    public enum Action: Equatable, Sendable {
        /// This launch is explicitly authorized to replace the older instance.
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

    /// The launching process's environment (only the override key is read).
    public let environment: [String: String]

    public init(environment: [String: String]) {
        self.environment = environment
    }

    public func action(currentBundleURL: URL, existingBundleURL: URL?) -> Action {
        guard existingBundleURL != nil else { return .yieldToExisting }
        if environment[Self.allowReplacingEnvironmentKey] == "1" { return .replaceExisting }
        return .yieldToExisting
    }

    /// Whether two bundle URLs resolve to the same installed application.
    public static func isSameBundle(_ lhs: URL, _ rhs: URL) -> Bool {
        canonical(lhs) == canonical(rhs)
    }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
