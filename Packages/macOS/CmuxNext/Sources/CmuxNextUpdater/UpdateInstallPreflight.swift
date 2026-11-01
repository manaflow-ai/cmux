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

    /// Sparkle's staged installation folder. A staged update is one entry in
    /// it (Sparkle 2.9.5; seen in the update harness, nx 1011-053940-192a39:
    /// removing it made the click quit the app for an installer that then
    /// failed). Only positive evidence refuses (a Sparkle layout change must
    /// never block every install): the folder exists and is empty, or its
    /// parent `org.sparkle-project.Sparkle` exists without it. With no parent
    /// either, the layout is unknown and the click proceeds.
    public let stagedInstallation: URL

    public init(bundle: URL, updateBytes: Int64?, stagedInstallation: URL) {
        self.bundle = bundle
        self.updateBytes = updateBytes
        self.stagedInstallation = stagedInstallation
    }

    /// Sparkle's installation folder for `bundleIdentifier` in the user's caches.
    public static func stagedInstallation(bundleIdentifier: String?) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "\(bundleIdentifier ?? "cmux")/org.sparkle-project.Sparkle/Installation", directoryHint: .isDirectory)
    }

    /// The first failed check, or nil when the install may start.
    public func failure(files: FileManager = .default) -> Failure? {
        if let failure = placeFailure(files: files) { return failure }
        if let staged = try? files.contentsOfDirectory(atPath: stagedInstallation.path) {
            return staged.contains(where: { !$0.hasPrefix(".") }) ? nil : .updateMissing
        }
        return files.fileExists(atPath: stagedInstallation.deletingLastPathComponent().path) ? .updateMissing : nil
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
        files.fileExists(atPath: stagedInstallation.deletingLastPathComponent().path)
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
