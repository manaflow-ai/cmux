public import Foundation

/// How cmux starts its Chromium host app: the executable and its arguments
/// (`CEFShim/src/browser_host_main.mm` reads them).
public nonisolated struct ChromiumHostConfiguration: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// The host app embed-cef.sh puts beside the helpers of `layout` in Debug
    /// builds (`<Product> Chromium Host.app`), or nil when this build has none.
    ///
    /// - Parameters:
    ///   - layout: The app's CEF runtime.
    ///   - rootCache: The host's own Chromium data folder: never the in-process
    ///     engine's, which Chromium's process singleton holds.
    ///   - bundleIdentifier: The app's, for the switch set (mock keychain in development bundles).
    ///   - environment: For the switch set's development overrides.
    ///   - fileManager: Checks that the host app exists.
    public static func bundled(in layout: CEFRuntimeLayout, rootCache: URL, bundleIdentifier: String?,
                               environment: [String: String], fileManager: FileManager = .default) -> ChromiumHostConfiguration? {
        let helper = layout.helperApp.deletingPathExtension().lastPathComponent
        guard helper.hasSuffix(" Helper") else { return nil }
        let name = String(helper.dropLast(" Helper".count)) + " Chromium Host"
        let executable = layout.frameworksDirectory.appending(path: "\(name).app/Contents/MacOS/\(name)")
        guard fileManager.isExecutableFile(atPath: executable.path) else { return nil }
        return ChromiumHostConfiguration(
            executable: executable,
            arguments: arguments(layout: layout, rootCache: rootCache, bundleIdentifier: bundleIdentifier, environment: environment))
    }

    static func arguments(layout: CEFRuntimeLayout, rootCache: URL, bundleIdentifier: String?,
                          environment: [String: String]) -> [String] {
        // The host refuses a fork without layer hosting, so the switch set is the one for
        // the resize-sync fork API (no AsyncLiveResize).
        let switches = CEFSwitches.current(forkAPIVersion: CEFSwitches.resizeSyncForkAPI,
                                           bundleIdentifier: bundleIdentifier, environment: environment).arguments
            // The host runs Chromium's own message loop: there is no external pump pass to slice.
            .filter { !$0.hasPrefix("cmux-pump-time-slice-us=") }
            // Chromium's code-sign clone copies the main bundle (here the small host app)
            // and starts helpers from the copy, but the helpers live outside it.
            + ["disable-features=MacAppCodeSignClone"]
        return ["--framework=\(layout.frameworkDirectory.path)",
                "--subprocess=\(layout.helperExecutable.path)",
                "--root-cache=\(rootCache.path)"]
            + switches.map { "--cef-switch=\($0)" }
    }
}
