public import Foundation

/// The "cmux Files (dev)" helper a DEV build embeds (docs/cmux-files-host.md): a pinned,
/// team-signed bundle (`com.cmuxterm.files.dev`) that starts this build's terminal daemon and
/// agent daemon as its own children, from a verified copy outside the app, with responsibility
/// disclaimed. macOS then charges their shells' and agents' Files and Folders checks to one
/// identity for every DEV build, instead of to each tag's app.
///
/// Only a DEV or staging build (`com.cmuxterm.app.debug[.<tag>]`, `com.cmuxterm.app.staging[.<tag>]`)
/// that embeds the helper uses it; Release, NIGHTLY, RC and stable never do, even with a copy
/// inside. `CMUX_NEXT_FILES_HOST=0` in the app's environment turns it off.
public nonisolated struct FilesHost: Sendable, Equatable {
    /// `cmux-tui server ensure` runs the owner it spawns through this launcher
    /// (`local_owner.rs` `OWNER_LAUNCHER_ENV`).
    public static let launcherEnvironmentKey = "CMUX_TUI_OWNER_LAUNCHER"
    /// `0` turns the helper off.
    public static let switchKey = "CMUX_NEXT_FILES_HOST"
    /// The embedded executable, relative to the app bundle (cmux-files-host `EMBEDDED_EXECUTABLE`).
    public static let embeddedExecutable = "Contents/Library/cmux Files (dev).app/Contents/MacOS/cmux-files-host"
    static let developmentBundlePrefixes = ["com.cmuxterm.app.debug", "com.cmuxterm.app.staging"]

    /// The embedded helper's executable.
    public let executable: URL

    /// The helper of the app at `bundleURL`, or nil when this build does not use one.
    public init?(
        bundleURL: URL,
        bundleIdentifier: String?,
        environment: [String: String],
        isExecutable: (String) -> Bool = { FileManager.checked.isExecutableFile(atPath: $0) }
    ) {
        guard environment[Self.switchKey] != "0",
              let bundleIdentifier,
              Self.developmentBundlePrefixes.contains(where: { bundleIdentifier == $0 || bundleIdentifier.hasPrefix($0 + ".") })
        else { return nil }
        let executable = bundleURL.appendingPathComponent(Self.embeddedExecutable)
        guard isExecutable(executable.path) else { return nil }
        self.executable = executable
    }

    /// This app's helper, or nil.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> FilesHost? {
        FilesHost(bundleURL: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier, environment: environment)
    }

    /// What `server ensure` gets so the owner it spawns runs under the helper.
    public var ownerEnvironment: [String: String] {
        [Self.launcherEnvironmentKey: executable.path]
    }

    /// `program`'s argv, run under the helper.
    public func arguments(running program: String) -> [String] {
        [executable.path, "run", "--", program]
    }
}
