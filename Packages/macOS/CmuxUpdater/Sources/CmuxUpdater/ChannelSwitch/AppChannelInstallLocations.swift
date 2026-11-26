public import Foundation

/// Finds app bundles LaunchServices knows for a bundle identifier.
public protocol InstalledAppLocating: Sendable {
    /// Every registered app URL for `bundleIdentifier`, in LaunchServices order.
    func applicationURLs(bundleIdentifier: String) -> [URL]
}

/// Where the switch looks for, and installs, the other app.
public struct AppChannelInstallLocations: Sendable {
    /// The system-wide Applications folder, normally `/Applications`.
    public let systemApplicationsDirectory: URL
    /// The per-user Applications folder, normally `~/Applications`.
    public let userApplicationsDirectory: URL

    /// Creates locations rooted at the given folders.
    public init(
        systemApplicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        userApplicationsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
    ) {
        self.systemApplicationsDirectory = systemApplicationsDirectory
        self.userApplicationsDirectory = userApplicationsDirectory
    }

    /// Picks the installed copy to open from LaunchServices' candidates, or `nil` when none
    /// counts as installed.
    ///
    /// Copies on a mounted disk image, in the Trash, under App Translocation, or nested inside
    /// another bundle are ignored, as are paths that no longer exist. A copy in the system
    /// Applications folder wins over one in the user's, which wins over anywhere else.
    ///
    /// - Parameters:
    ///   - candidates: LaunchServices' URLs for the target bundle identifier.
    ///   - fileExists: Whether a path is still on disk.
    public func preferredInstalledApp(
        from candidates: [URL],
        fileExists: (URL) -> Bool
    ) -> URL? {
        let usable = candidates
            .map(\.standardizedFileURL)
            .filter { Self.isInstalledLocation($0) && fileExists($0) }
        func isDirectChild(_ url: URL, of directory: URL) -> Bool {
            url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path
        }
        return usable.first { isDirectChild($0, of: systemApplicationsDirectory) }
            ?? usable.first { isDirectChild($0, of: userApplicationsDirectory) }
            ?? usable.first
    }

    /// Where a freshly downloaded `appName` (for example `cmux NIGHTLY.app`) is installed:
    /// the system Applications folder when it is writable, otherwise the user's.
    ///
    /// - Parameters:
    ///   - appName: The bundle's file name, copied from the disk image.
    ///   - isWritableDirectory: Whether the current user can create files in a folder.
    public func installDestination(
        appName: String,
        isWritableDirectory: (URL) -> Bool
    ) -> URL {
        let directory = isWritableDirectory(systemApplicationsDirectory)
            ? systemApplicationsDirectory
            : userApplicationsDirectory
        return directory.appendingPathComponent(appName, isDirectory: true)
    }

    static func isInstalledLocation(_ url: URL) -> Bool {
        let components = url.pathComponents
        if components.count > 1, components[1] == "Volumes" { return false }
        if components.contains(".Trash") || components.contains("AppTranslocation") { return false }
        // An .app inside another bundle (a helper or an embedded copy) is not an install.
        let parentComponents = components.dropLast()
        return !parentComponents.contains { $0.hasSuffix(".app") }
    }
}
