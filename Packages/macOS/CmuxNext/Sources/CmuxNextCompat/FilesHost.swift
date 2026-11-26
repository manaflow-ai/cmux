#if canImport(Darwin)
public import Foundation

/// The "cmux Files (dev)" helper a DEV build embeds (docs/cmux-files-host.md): a pinned,
/// team-signed bundle (`com.cmuxterm.files.dev`) that starts this build's terminal daemon and
/// agent daemon as its own children, from a verified copy outside the app, with responsibility
/// disclaimed. macOS then charges their shells' and agents' Files and Folders checks to one
/// identity for every DEV build, instead of to each tag's app.
///
/// Dev only, by construction: only a Debug compile (`#if DEBUG`) of a DEV build
/// (`com.cmuxterm.app.debug[.<tag>]`) that embeds the helper uses it. Every Release-configuration
/// product (stable, NIGHTLY, RC, staging, the NEXT DEV daily, `--release` dogfood tags) compiles
/// the check to nil and never looks for the helper, even with a copy inside; staging is excluded
/// by bundle id too, because it is a shipping channel. `CMUX_NEXT_FILES_HOST=0` in the app's
/// environment turns it off.
public nonisolated struct FilesHost: Sendable, Equatable {
    /// `cmux-tui server ensure` runs the owner it spawns through this launcher
    /// (`local_owner.rs` `OWNER_LAUNCHER_ENV`).
    public static let launcherEnvironmentKey = "CMUX_TUI_OWNER_LAUNCHER"
    /// `0` turns the helper off.
    public static let switchKey = "CMUX_NEXT_FILES_HOST"
    /// The embedded executable, relative to the app bundle (cmux-files-host `EMBEDDED_EXECUTABLE`).
    public static let embeddedExecutable = "Contents/Library/cmux Files (dev).app/Contents/MacOS/cmux-files-host"
    /// The helper's executable name (cmux-files-host `EXECUTABLE`), as `proc_pidpath` ends.
    public static let executableName = "cmux-files-host"
    static let developmentBundlePrefix = "com.cmuxterm.app.debug"

    /// Whether this compile is a Debug build. Release configurations compile it to `false`, so a
    /// shipped build never resolves, stats or runs the helper.
    public static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// The embedded helper's executable.
    public let executable: URL

    /// The helper of the app at `bundleURL`, or nil when this build does not use one. The checks
    /// that need no disk come first, so a Release compile or a non-DEV bundle never stats it.
    public init?(
        bundleURL: URL,
        bundleIdentifier: String?,
        environment: [String: String],
        isDebugBuild: Bool = FilesHost.isDebugBuild,
        isExecutable: (String) -> Bool = { FileManager.checked.isExecutableFile(atPath: $0) }
    ) {
        guard isDebugBuild,
              environment[Self.switchKey] != "0",
              let bundleIdentifier,
              bundleIdentifier == Self.developmentBundlePrefix
                || bundleIdentifier.hasPrefix(Self.developmentBundlePrefix + ".")
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
#endif
