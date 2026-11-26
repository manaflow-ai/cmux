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

    /// The host embed-cef.sh puts in the app's `Contents/MacOS` in Debug builds
    /// (`<Product> Chromium Host`, beside the app's own executable: its main
    /// bundle is the app, whose framework and helpers Chromium's helper sandbox
    /// lets the helpers read), or nil when this build has none.
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
        let executable = layout.frameworksDirectory.deletingLastPathComponent().appending(path: "MacOS/\(name)")
        guard fileManager.isExecutableFile(atPath: executable.path) else { return nil }
        return ChromiumHostConfiguration(
            executable: executable,
            arguments: arguments(layout: layout, rootCache: rootCache, bundleIdentifier: bundleIdentifier, environment: environment))
    }

    /// The same host for another page of this app: its own data folder (`<root cache>-<suffix>`, as Chromium's
    /// process singleton holds one per browser process) and, with `remoteCocoa`, the remote Cocoa mode (fork API 37:
    /// the page's own views in cmux's window; `browser_host_main.mm`).
    public func variant(suffix: String?, remoteCocoa: Bool) -> ChromiumHostConfiguration {
        var copy = self
        if let suffix {
            copy.arguments = arguments.map { $0.hasPrefix("--root-cache=") ? $0 + "-" + suffix : $0 }
        }
        if remoteCocoa, !copy.arguments.contains("--remote-cocoa") { copy.arguments.append("--remote-cocoa") }
        return copy
    }

    static func arguments(layout: CEFRuntimeLayout, rootCache: URL, bundleIdentifier: String?,
                          environment: [String: String]) -> [String] {
        // The host refuses a fork without layer hosting, so the switch set is the one for
        // the resize-sync fork API (no AsyncLiveResize).
        var switchSet = CEFSwitches.current(forkAPIVersion: CEFSwitches.resizeSyncForkAPI,
                                            bundleIdentifier: bundleIdentifier, environment: environment)
        // The host has its own data and sets no keychain item of its own: on the real keychain its
        // Chromium would read the shared "Chromium Safe Storage" item and macOS would ask (CEFKeychainItem).
        switchSet.useMockKeychain = true
        let switches = switchSet.arguments
            // The host runs Chromium's own message loop: there is no external pump pass to slice.
            .filter { !$0.hasPrefix("cmux-pump-time-slice-us=") }
            // Chromium's code-sign clone copies the main bundle (here the whole app, the
            // host's main bundle) for every host it starts: off, as it was for the old host app.
            + ["disable-features=MacAppCodeSignClone"]
        return ["--framework=\(layout.frameworkDirectory.path)",
                "--subprocess=\(layout.helperExecutable.path)",
                "--root-cache=\(rootCache.path)"]
            + switches.map { "--cef-switch=\($0)" }
    }
}
