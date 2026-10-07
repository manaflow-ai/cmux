public import Foundation

/// What detection needs from the system: a home directory (a fixture folder
/// in tests and test launches) and a way to find installed apps.
public struct ImportEnvironment: Sendable {
    public var homeDirectory: URL
    /// Finds an app by bundle id; nil when it is not installed.
    public var locateApp: @Sendable (String) -> URL?

    public init(homeDirectory: URL, locateApp: @escaping @Sendable (String) -> URL?) {
        self.homeDirectory = homeDirectory
        self.locateApp = locateApp
    }

    /// Environment variable that points import at a fixture home (test
    /// launches only; never the user's real profiles in tests).
    public static let fixtureHomeKey = "CMUX_NEXT_BROWSER_IMPORT_HOME"

    /// The real home, or the fixture home from the environment. With a
    /// fixture home, apps are not looked up, so the result does not depend
    /// on what this Mac has installed.
    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        locateApp: @escaping @Sendable (String) -> URL?
    ) -> ImportEnvironment {
        if let fixture = environment[fixtureHomeKey], !fixture.isEmpty {
            return ImportEnvironment(homeDirectory: URL(fileURLWithPath: fixture, isDirectory: true), locateApp: { _ in nil })
        }
        return ImportEnvironment(homeDirectory: FileManager.default.homeDirectoryForCurrentUser, locateApp: locateApp)
    }

    public func dataDirectory(_ browser: ImportBrowser) -> URL {
        homeDirectory.appending(path: browser.dataDirectory, directoryHint: .isDirectory)
    }
}

/// How a file responds to an open attempt.
public enum FileAccess: Sendable, Equatable {
    case readable
    case missing
    /// EPERM/EACCES: macOS privacy protection (Full Disk Access) or permissions.
    case denied

    /// Opens the file read-only (and closes it) to learn whether it can be
    /// read. `access(2)` is not enough: it reports success for files that
    /// privacy protection (TCC) still blocks.
    public static func probe(_ url: URL) -> FileAccess {
        let fd = open(url.path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return .readable
        }
        switch errno {
        case EPERM, EACCES: return .denied
        default: return .missing
        }
    }
}
