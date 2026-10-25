#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
public import Foundation

/// How cmux starts its Chromium host app: the executable and its arguments
/// (`ChromiumHost/src/browser_host_main.mm` reads them).
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
        // The host refuses a fork below API 27 (kMinForkAPI in chromium_host_wire.h; it exits 66):
        // layer hosting (26) and the resize sync (27). So the switch set is the one for API 27
        // (no AsyncLiveResize), which is every fork the host runs on.
        let switches = CEFSwitches.current(forkAPIVersion: CEFSwitches.resizeSyncForkAPI,
                                           bundleIdentifier: bundleIdentifier, environment: environment).arguments
            // The host runs Chromium's own message loop: there is no external pump pass to slice.
            .filter { !$0.hasPrefix("cmux-pump-time-slice-us=") }
            // Chromium's code-sign clone copies the main bundle (here the small host app)
            // and starts helpers from the copy, but the helpers live outside it.
            + ["disable-features=MacAppCodeSignClone"]
            // Development override (Debug only, like the host): more host switches, comma-separated, for
            // diagnosis on a measure host (chromium-host-bench.py --host-switches: child logging, no-sandbox).
            + (environment["CMUX_NEXT_CHROMIUM_HOST_SWITCHES"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        // The main bundle is the app's (as in process), never the host's own small bundle: it holds the
        // framework and the helpers Chromium starts and sandboxes (browser_host_main.mm).
        return ["--framework=\(layout.frameworkDirectory.path)",
                "--subprocess=\(layout.helperExecutable.path)",
                "--main-bundle=\(layout.mainBundle.path)",
                "--root-cache=\(rootCache.path)",
                "--log-file=\(logFile(rootCache: rootCache).path)"]
            + switches.map { "--cef-switch=\($0)" }
    }

    /// Chromium's log of a host whose data folder is `rootCache` (warnings and
    /// fatal messages): where a host that ended says why.
    static func logFile(rootCache: URL) -> URL {
        rootCache.appending(path: "chromium-host.log")
    }

    /// The `--log-file` this configuration passes, or nil.
    public var logFile: String? {
        arguments.first { $0.hasPrefix("--log-file=") }.map { String($0.dropFirst("--log-file=".count)) }
    }
}
#endif
