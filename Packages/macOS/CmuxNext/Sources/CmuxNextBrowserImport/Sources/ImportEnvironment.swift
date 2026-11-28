public import Foundation

/// What detection needs from the system: a home directory (a fixture folder
/// in tests and test launches) and a way to find installed apps.
public struct ImportEnvironment: Sendable {
    public var homeDirectory: URL
    /// Finds an app by bundle id; nil when it is not installed.
    public var locateApp: @Sendable (String) -> URL?
    /// Finds an app by name ("Fellou" for Fellou.app), for registry rows
    /// whose bundle id is not verified; nil when it is not installed.
    public var locateAppNamed: @Sendable (String) -> URL?

    public init(homeDirectory: URL, locateApp: @escaping @Sendable (String) -> URL?,
                locateAppNamed: @escaping @Sendable (String) -> URL? = { _ in nil }) {
        self.homeDirectory = homeDirectory
        self.locateApp = locateApp
        self.locateAppNamed = locateAppNamed
    }

    /// `/Applications/<name>.app` or `~/Applications/<name>.app`.
    public static func applicationNamed(_ name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let folders = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                       FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)]
        return folders.map { $0.appending(path: "\(name).app", directoryHint: .isDirectory) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Environment variable that points import at a fixture home (test
    /// launches only; never the user's real profiles in tests).
    public static let fixtureHomeKey = "CMUX_NEXT_BROWSER_IMPORT_HOME"

    /// Whether this build honors the fixture seams (`fixtureHomeKey`,
    /// `FixtureSafeStorage.environmentKey`): DEBUG builds only, so a Release
    /// build always reads the real home and the login Keychain.
    public static var fixturesAllowed: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// The real home, or the fixture home from the environment (DEBUG
    /// builds). With a fixture home, apps are not looked up, so the result
    /// does not depend on what this Mac has installed.
    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowsFixtures: Bool = fixturesAllowed,
        locateApp: @escaping @Sendable (String) -> URL?
    ) -> ImportEnvironment {
        if allowsFixtures, let fixture = environment[fixtureHomeKey], !fixture.isEmpty {
            return ImportEnvironment(homeDirectory: URL(fileURLWithPath: fixture, isDirectory: true), locateApp: { _ in nil })
        }
        return ImportEnvironment(homeDirectory: FileManager.default.homeDirectoryForCurrentUser, locateApp: locateApp,
                                 locateAppNamed: applicationNamed)
    }

    /// The browser's data folder in this home: the first registry folder
    /// that exists, else the first one.
    public func dataDirectory(_ browser: ImportBrowser) -> URL {
        let candidates = browser.dataDirectories.map { homeDirectory.appending(path: $0, directoryHint: .isDirectory) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? homeDirectory.appending(path: browser.dataDirectory, directoryHint: .isDirectory)
    }

    /// A home-relative registry path (Arc's sidebar, Safari's cookies) in this home.
    public func file(_ relative: String) -> URL {
        homeDirectory.appending(path: relative)
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
