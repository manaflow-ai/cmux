public import Foundation

/// Which `cmux` a shell runs: the first `cmux` on the login `PATH` that it can
/// execute. A link at /usr/local/bin/cmux is not enough when an earlier PATH
/// folder (Homebrew's /opt/homebrew/bin on Apple silicon) holds another one,
/// and a link into an app that was moved to the Trash dangles with nothing
/// saying so. Install and the launch offer read this first.
public nonisolated struct CLIPathCheck: Equatable, Sendable {
    /// Classic cmux's bundle identifier: its CLI is named as classic's.
    public static let classicBundleID = "com.cmuxterm.app"

    public nonisolated enum Status: Equatable, Sendable {
        /// The first `cmux` on PATH is this app's CLI.
        case thisApp
        /// No `cmux` on PATH.
        case missing
        /// No `cmux` runs, and `entry` links into a cmux app that is gone
        /// (`target`): shells skip it, so `cmux` is "command not found".
        case dangling(target: String)
        /// The first `cmux` on PATH is the CLI of another cmux app, `bundle`
        /// (classic, or another copy of this one).
        case otherApp(bundle: String, classic: Bool)
        /// The first `cmux` on PATH is not in a cmux app's bundle (a build of
        /// the CLI, a package manager's, another app's).
        case foreign
    }

    public let status: Status
    /// The `cmux` the status is about: the one that runs, or the dangling
    /// link; nil when `missing` or `thisApp` is all there is to say.
    public let entry: URL?
    /// Where a plain install puts the link: the dangling link itself (it is
    /// repointed), else /usr/local/bin/cmux, else the first standard folder
    /// on PATH when /usr/local/bin is not on it.
    public let installDestination: URL
    /// This app runs from its disk image or a translocated copy, so a link
    /// to its CLI would dangle (``CLIPathInstaller/runsFromImage(_:)``).
    public let appRunsFromImage: Bool

    /// When the app has no login `PATH` yet: the folders `path_helper` and
    /// Homebrew's shell setup put first on a Mac.
    public static let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// The check for `path` (the login `PATH`, else ``fallbackPath``), off
    /// the caller's actor: it reads the file system.
    @concurrent public static func current(path: String?, source: URL) async -> CLIPathCheck {
        CLIPathCheck(path: path ?? fallbackPath, source: source)
    }

    /// The `cmux` on `path` (a `PATH` value) compared with `source`, this
    /// app's bundled CLI.
    public init(path: String, source: URL) {
        let fileManager = FileManager.default
        appRunsFromImage = CLIPathInstaller.runsFromImage(source)
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        var seen = Set<String>()
        var folders: [String] = []
        // Only absolute folders: an empty or relative entry depends on the shell's working
        // folder, which differs per shell, so it has no one answer here.
        for folder in path.split(separator: ":").map(String.init) where folder.hasPrefix("/") && seen.insert(folder).inserted {
            folders.append(folder)
        }
        var dangling: (URL, String)?
        var found: (Status, URL)?
        for folder in folders {
            let entry = URL(fileURLWithPath: folder).appendingPathComponent("cmux")
            guard (try? fileManager.attributesOfItem(atPath: entry.path)) != nil else { continue }
            let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
                // A link into a cmux app that is gone: ours to repoint. Any
                // other broken link is left alone, as a shell skips it too,
                // and so is one inside an app bundle (never modified).
                if dangling == nil, !Self.isInsideApp(entry), let target = try? fileManager.destinationOfSymbolicLink(atPath: entry.path),
                   Self.appBundle(containing: URL(fileURLWithPath: target, relativeTo: entry.deletingLastPathComponent())
                       .standardizedFileURL.path) != nil {
                    dangling = (entry, target)
                }
                continue
            }
            guard !isDirectory.boolValue, fileManager.isExecutableFile(atPath: resolved.path) else { continue }
            if resolved == source {
                found = (.thisApp, entry)
            } else if let bundle = Self.appBundle(containing: resolved.path),
                      let id = Bundle(url: URL(fileURLWithPath: bundle))?.bundleIdentifier, Self.isCmux(id) {
                found = (.otherApp(bundle: bundle, classic: id == Self.classicBundleID), entry)
            } else {
                found = (.foreign, entry)
            }
            break
        }
        let standard = CLIPathInstaller.Name.cmux.destination
        let fallback = folders.contains(standard.deletingLastPathComponent().path) ? standard
            : ["/opt/homebrew/bin", "/usr/local/bin"].first(where: { folders.contains($0) })
                .map { URL(fileURLWithPath: $0).appendingPathComponent("cmux") } ?? standard
        switch (found, dangling) {
        case let ((status, entry)?, _):
            self.status = status
            self.entry = entry
            installDestination = fallback
        case let (nil, (entry, target)?):
            status = .dangling(target: target)
            self.entry = entry
            installDestination = entry
        case (nil, nil):
            status = .missing
            entry = nil
            installDestination = fallback
        }
    }

    /// Whether `cmux` in a new shell runs this app's CLI.
    public var runsThisApp: Bool { status == .thisApp }

    /// Where Replace points `cmux` at this app: the entry that runs (or
    /// dangles) instead, else the plain install's place. Never a file inside
    /// an app bundle (a PATH folder in another app's Contents): replacing it
    /// would break that app's signature and its own CLI.
    public var replaceDestination: URL {
        guard let entry, !entryIsInsideApp else { return installDestination }
        switch status {
        case .otherApp, .foreign, .dangling: return entry
        case .thisApp, .missing: return installDestination
        }
    }

    /// The entry is a file inside an `.app` (its PATH folder is in a bundle),
    /// not a link a person or an installer put in a bin folder.
    public var entryIsInsideApp: Bool {
        entry.map(Self.isInsideApp) ?? false
    }

    /// Whether `entry`'s folder, its links resolved (a ~/bin that links into
    /// an app's Contents), is inside an `.app`. The entry itself, perhaps a
    /// link, is not resolved: only where it sits counts.
    static func isInsideApp(_ entry: URL) -> Bool {
        appBundle(containing: entry.deletingLastPathComponent().resolvingSymlinksInPath().path) != nil
    }

    /// What Uninstall removes: /usr/local/bin/cmux, as before, and the link
    /// on PATH that runs this app when it is elsewhere (a repointed
    /// /opt/homebrew/bin/cmux).
    public var uninstallDestinations: [URL] {
        let standard = CLIPathInstaller.Name.cmux.destination
        guard status == .thisApp, let entry, entry != standard, !entryIsInsideApp else { return [standard] }
        return [standard, entry]
    }

    /// Whether `id` is a cmux app's bundle identifier (classic, NIGHTLY, a DEV build).
    static func isCmux(_ id: String) -> Bool {
        id == classicBundleID || id.hasPrefix(classicBundleID + ".")
    }

    /// The `.app` folder `path` is inside, or nil.
    static func appBundle(containing path: String) -> String? {
        var bundle = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            bundle += "/" + component
            if component.lowercased().hasSuffix(".app") { return bundle }
        }
        return nil
    }
}

public extension CLIPathCheck.Status {
    /// The `cmux` that runs is cmux classic's.
    var isClassic: Bool {
        if case .otherApp(_, true) = self { return true }
        return false
    }
}
