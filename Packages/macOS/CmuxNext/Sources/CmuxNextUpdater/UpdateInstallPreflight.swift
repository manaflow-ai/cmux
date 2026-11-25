public import Foundation

/// The checks before Restart to Update hands the app to the installer
/// (cx-ncc.45.7). Sparkle's installer replaces the bundle after the app quit,
/// so a failure there leaves no app on screen and no message: a read-only
/// folder made the app vanish (update harness nx 1011-044617-6401b4). Each
/// check here reads the file system only; a failure keeps the app running
/// and shows the update error with Download Manually.
nonisolated public struct UpdateInstallPreflight: Sendable {
    public enum Failure: Equatable, Sendable {
        /// The bundle or its folder is not writable (path of the folder).
        case folderNotWritable(String)
        /// Free bytes on the app's volume, and the bytes the install needs.
        case notEnoughSpace(free: Int64, needed: Int64)
        /// Sparkle's staged installation folder is empty or gone.
        case updateMissing
    }

    /// Room for the staged copy and the replaced bundle (at least this much).
    public static let minimumFreeBytes: Int64 = 512 * 1024 * 1024

    public let bundle: URL
    /// The update's archive size, when the appcast gave one.
    public let updateBytes: Int64?

    /// Sparkle's staged installation folders, the app's own first. A staged update is one entry in
    /// one of them (Sparkle 2.9.5; seen in the update harness, nx 1011-053940-192a39: removing it made
    /// the click quit the app for an installer that then failed). Only positive evidence refuses (a
    /// Sparkle layout change must never block every install): no folder holds an entry, and one of them
    /// exists empty or its parent `org.sparkle-project.Sparkle` exists without it. With no parent
    /// anywhere, the layout is unknown and the click proceeds.
    ///
    /// Two folders because two processes resolve "the user's caches": the app from its `HOME`, and
    /// Sparkle's installer, which launchd starts with the account's home. They differ when the app runs
    /// with its own `HOME` (the release rollback drill's walk home): the app's folder is the empty one
    /// ``UpdateController`` creates, and the update sits in the account's (drill 11, hq run
    /// 45422799252: "install preflight failed: updateMissing" one second after Sparkle staged it).
    public let stagedInstallations: [URL]

    public init(bundle: URL, updateBytes: Int64?, stagedInstallation: URL) {
        self.init(bundle: bundle, updateBytes: updateBytes, stagedInstallations: [stagedInstallation])
    }

    public init(bundle: URL, updateBytes: Int64?, stagedInstallations: [URL]) {
        self.bundle = bundle
        self.updateBytes = updateBytes
        self.stagedInstallations = stagedInstallations
    }

    /// Sparkle's installation folder for `bundleIdentifier` in the user's caches, as this app resolves
    /// them (from its `HOME`).
    public static func stagedInstallation(bundleIdentifier: String?) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: installationPath(bundleIdentifier), directoryHint: .isDirectory)
    }

    /// The folders Sparkle may have staged into: the app's own (``stagedInstallation(bundleIdentifier:)``),
    /// then the account home's when that is another folder (`accountHome`, the password database's home
    /// by default, the one launchd gives Sparkle's installer).
    public static func stagedInstallations(bundleIdentifier: String?, accountHome: URL? = accountHome()) -> [URL] {
        let own = stagedInstallation(bundleIdentifier: bundleIdentifier)
        guard let accountHome else { return [own] }
        let account = accountHome.appending(path: "Library/Caches", directoryHint: .isDirectory)
            .appending(path: installationPath(bundleIdentifier), directoryHint: .isDirectory)
        return account.standardizedFileURL.path == own.standardizedFileURL.path ? [own] : [own, account]
    }

    /// The account's home from the password database, which a `HOME` override does not change.
    public static func accountHome() -> URL? {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
        let path = String(cString: dir)
        return path.isEmpty ? nil : URL(filePath: path, directoryHint: .isDirectory)
    }

    private static func installationPath(_ bundleIdentifier: String?) -> String {
        "\(bundleIdentifier ?? "cmux")/org.sparkle-project.Sparkle/Installation"
    }

    private static func holdsUpdate(_ folder: URL, files: FileManager) -> Bool {
        (try? files.contentsOfDirectory(atPath: folder.path))?.contains(where: { !$0.hasPrefix(".") }) ?? false
    }

    /// The first failed check, or nil when the install may start.
    public func failure(files: FileManager = .default) -> Failure? {
        if let failure = placeFailure(files: files) { return failure }
        var missing = false
        for folder in stagedInstallations {
            if Self.holdsUpdate(folder, files: files) { return nil }
            if files.fileExists(atPath: folder.path) || files.fileExists(atPath: folder.deletingLastPathComponent().path) {
                missing = true
            }
        }
        return missing ? .updateMissing : nil
    }

    /// The checks of where the app is: its folder is writable and its volume has room. They
    /// also explain an install that failed after the app quit (``UpdateInstallFailure``).
    public func placeFailure(files: FileManager = .default) -> Failure? {
        let folder = bundle.deletingLastPathComponent()
        guard files.isWritableFile(atPath: folder.path), files.isWritableFile(atPath: bundle.path) else {
            return .folderNotWritable(folder.path)
        }
        let needed = max(Self.minimumFreeBytes, (updateBytes ?? 0) * 3)
        if let values = try? bundle.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage, free < needed {
            return .notEnoughSpace(free: free, needed: needed)
        }
        return nil
    }

    /// Whether the staged-update check could read Sparkle's folders (false:
    /// the layout is unknown and the check let the click through).
    public func knowsStagedLayout(files: FileManager = .default) -> Bool {
        stagedInstallations.contains { files.fileExists(atPath: $0.deletingLastPathComponent().path) }
    }

    /// What the update error says.
    public static func message(_ failure: Failure) -> String {
        switch failure {
        case .folderNotWritable(let folder): UpdaterStrings.preflightFolder(folder)
        case .notEnoughSpace: UpdaterStrings.preflightSpace
        case .updateMissing: UpdaterStrings.preflightMissing
        }
    }
}
