public import Foundation

/// Finds the Xcode that iOS simulators need, without running `xcrun`.
///
/// On a Mac with no developer tools, `/usr/bin/xcrun` is a stub that pops up
/// macOS's "install the command line developer tools" dialog. That dialog
/// installs only the command line tools, which have no simulators, so cmux
/// must never trigger it: it checks the file system first and runs Xcode's
/// tools only when an Xcode is there.
///
/// It also fixes the most common setup trap: Xcode is installed, but
/// `xcode-select` still points at the command line tools (they were
/// installed first). `xcrun simctl` then fails. The locator returns the
/// installed Xcode's Developer folder instead, and the runner passes it as
/// `DEVELOPER_DIR`, so the user never needs `sudo xcode-select -s`.
///
/// ```swift
/// let xcode = XcodeLocator()
/// if let developer = xcode.developerDirectory() { /* run simctl with DEVELOPER_DIR=developer */ }
/// ```
public struct XcodeLocator: Sendable {
    private let environment: [String: String]
    private let selectedLink: @Sendable () -> String?
    private let fileExists: @Sendable (String) -> Bool
    private let applications: @Sendable () -> [String]

    /// - Parameters:
    ///   - environment: the process environment; a valid `DEVELOPER_DIR` wins.
    ///   - selectedLink: where `xcode-select -s` points (`/var/db/xcode_select_link`).
    ///   - fileExists: checks a path (tests fake the file system).
    ///   - applications: the `Xcode*.app` bundles in `/Applications` and `~/Applications`.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        selectedLink: @escaping @Sendable () -> String? = { try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") },
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        applications: @escaping @Sendable () -> [String] = XcodeLocator.installedXcodeApps
    ) {
        self.environment = environment
        self.selectedLink = selectedLink
        self.fileExists = fileExists
        self.applications = applications
    }

    /// The Developer folder of an Xcode that has `simctl`, or nil when no Xcode is installed.
    ///
    /// Order: `DEVELOPER_DIR`, then the `xcode-select` choice when it is an
    /// Xcode, then `Xcode.app`, then any other `Xcode*.app` (a beta), newest name first.
    public func developerDirectory() -> String? {
        if let dir = environment["DEVELOPER_DIR"], hasSimctl(dir) { return dir }
        if let linked = selectedLink(), hasSimctl(linked) { return linked }
        let apps = applications().sorted { lhs, rhs in
            let l = (lhs as NSString).lastPathComponent, r = (rhs as NSString).lastPathComponent
            if (l == "Xcode.app") != (r == "Xcode.app") { return l == "Xcode.app" }
            return l.localizedStandardCompare(r) == .orderedDescending
        }
        return apps.map { $0 + "/Contents/Developer" }.first(where: hasSimctl)
    }

    /// The Xcode app that ``developerDirectory()`` belongs to (`…/Xcode.app`), for "Open Xcode".
    public func xcodeApp() -> String? {
        guard let developer = developerDirectory(), developer.hasSuffix("/Contents/Developer") else { return nil }
        return String(developer.dropLast("/Contents/Developer".count))
    }

    /// True when only the command line tools are installed (they have no simulators).
    public var hasOnlyCommandLineTools: Bool {
        developerDirectory() == nil && fileExists("/Library/Developer/CommandLineTools/usr/bin/clang")
    }

    private func hasSimctl(_ developer: String) -> Bool {
        !developer.isEmpty && fileExists(developer + "/usr/bin/simctl")
    }

    /// The `Xcode*.app` bundles in `/Applications` and `~/Applications`.
    public static let installedXcodeApps: @Sendable () -> [String] = {
        let folders = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        return folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
                .map { folder + "/" + $0 }
        }
    }
}
