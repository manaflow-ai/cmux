public import Foundation

/// Restart to Update hands the app to Sparkle's installer, which swaps the bundle after the app has
/// quit. When the swap fails there is no app on screen to say so: Sparkle reopens the old build,
/// the update stages again and the card offers Restart to Update as if nothing happened (Leo
/// 2026-10-21: "If an installed update ever fails, the app must say why instead of offering
/// Restart again.").
///
/// Just before Sparkle relaunches, the updater records here which build it installs over which.
/// The next launch reads the record once (``consume(defaults:build:now:)``): still on the old
/// build, the install failed, and the staged update card says why (``UpdateInstallFailure``).
public nonisolated struct UpdateInstallCheck: Codable, Equatable, Sendable {
    /// The running build when the install began (`CFBundleVersion`).
    public var fromBuild: String
    /// The build Sparkle installs.
    public var targetBuild: String
    public var recordedAt: Date

    public init(fromBuild: String, targetBuild: String, recordedAt: Date) {
        self.fromBuild = fromBuild
        self.targetBuild = targetBuild
        self.recordedAt = recordedAt
    }

    /// The defaults key of the record (the app's own domain, so each build channel keeps its own).
    public static let key = "cmux.next.updates.installCheck"
    /// A record older than this judges nothing: the launch it was written for is long past.
    public static let maxAge: TimeInterval = 24 * 60 * 60

    /// What this launch says about the install the record was written for.
    public enum Outcome: Equatable, Sendable {
        /// The relaunch runs the build Sparkle installed.
        case installed
        /// The relaunch runs the build the install was meant to replace.
        case failed
    }

    /// The outcome for a launch of `build`, or nil when the record says nothing about it: stale,
    /// written in the future, a no-op install, or a third build (one installed by hand).
    public func outcome(runningBuild build: String, now: Date) -> Outcome? {
        let age = now.timeIntervalSince(recordedAt)
        guard age >= -60, age <= Self.maxAge, fromBuild != targetBuild else { return nil }
        if build == targetBuild { return .installed }
        if build == fromBuild { return .failed }
        return nil
    }

    /// Writes `record`, or removes any record (nil: Sparkle did not name the build it installs).
    public static func write(_ record: UpdateInstallCheck?, defaults: UserDefaults) {
        guard let record, let data = try? JSONEncoder().encode(record) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    /// Reads and clears the record at launch: the record and this launch's outcome, else nil (no
    /// record, unreadable, or one that says nothing about this launch).
    public static func consume(defaults: UserDefaults, build: String, now: Date = Date())
        -> (record: UpdateInstallCheck, outcome: Outcome)? {
        let data = defaults.data(forKey: key)
        if data != nil { defaults.removeObject(forKey: key) }
        guard let record = data.flatMap({ try? JSONDecoder().decode(UpdateInstallCheck.self, from: $0) }),
              let outcome = record.outcome(runningBuild: build, now: now) else { return nil }
        return (record, outcome)
    }
}

/// Why an install left the old build running, read from the file system at the launch after it.
/// Sparkle's installer runs after the app quit and leaves no error the app can read, so these are
/// the causes the app can see for itself; anything else says the installer gave no reason.
public nonisolated enum UpdateInstallFailure: Equatable, Sendable {
    /// macOS runs the app from a randomized read-only copy (App Translocation: the app was opened
    /// from Downloads or a disk image without being moved), which no installer can replace.
    case translocated
    /// The app's bundle or its folder is not writable (path of the folder).
    case folderNotWritable(String)
    /// Free bytes on the app's volume, and the bytes an install needs.
    case notEnoughSpace(free: Int64, needed: Int64)
    /// None of the above: the installer left the old build and no cause shows.
    case notReplaced

    /// The cause for the app at `bundle`. Only the place checks of ``UpdateInstallPreflight``
    /// apply: Sparkle removes its staged copy whether the install worked or not.
    public static func diagnose(bundle: URL, files: FileManager = .default) -> UpdateInstallFailure {
        if bundle.path.contains("/AppTranslocation/") { return .translocated }
        let preflight = UpdateInstallPreflight(bundle: bundle, updateBytes: nil,
                                               stagedInstallation: UpdateInstallPreflight.stagedInstallation(bundleIdentifier: nil))
        switch preflight.placeFailure(files: files) {
        case .folderNotWritable(let folder): return .folderNotWritable(folder)
        case .notEnoughSpace(let free, let needed): return .notEnoughSpace(free: free, needed: needed)
        case .updateMissing, nil: return .notReplaced
        }
    }

    /// The staged update card's one-line reason.
    public var summary: String {
        switch self {
        case .translocated: UpdaterStrings.installFailedTranslocatedShort
        case .folderNotWritable: UpdaterStrings.installFailedFolderShort
        case .notEnoughSpace: UpdaterStrings.installFailedSpaceShort
        case .notReplaced: UpdaterStrings.installFailedUnknownShort
        }
    }

    /// The full reason and what to do (the card's popover and button help).
    public var message: String {
        switch self {
        case .translocated: UpdaterStrings.installFailedTranslocated
        case .folderNotWritable(let folder): UpdaterStrings.installFailedFolder(folder)
        case .notEnoughSpace: UpdaterStrings.installFailedSpace
        case .notReplaced: UpdaterStrings.installFailedUnknown
        }
    }
}
