#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug and bench builds only (embed-cef.sh), and so does its Swift side.
public import Foundation
import CmuxNextCompat

/// How cmux starts its Chromium host app: the executable and its arguments
/// (`ChromiumHost/src/browser_host_main.mm` reads them).
public nonisolated struct ChromiumHostConfiguration: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// The host embed-cef.sh puts into the app's own `Contents/MacOS` in Debug
    /// and bench builds (`<Product> Chromium Host`), or nil when this build has none.
    ///
    /// A second executable of the app, not an app of its own: Chromium gives
    /// its sandboxed helpers read access to the browser process's main bundle
    /// only, and the app is the bundle that holds the framework and the helpers.
    ///
    /// - Parameters:
    ///   - layout: The app's CEF runtime.
    ///   - rootCache: The host's own Chromium data folder: never the in-process
    ///     engine's, which Chromium's process singleton holds.
    ///   - bundleIdentifier: The app's, for the switch set (mock keychain in development bundles).
    ///   - environment: For the switch set's development overrides.
    public static func bundled(in layout: CEFRuntimeLayout, rootCache: URL, bundleIdentifier: String?,
                               environment: [String: String]) -> ChromiumHostConfiguration? {
        let helper = layout.helperApp.deletingPathExtension().lastPathComponent
        guard helper.hasSuffix(" Helper") else { return nil }
        let name = String(helper.dropLast(" Helper".count)) + " Chromium Host"
        let executable = layout.mainBundle.appending(path: "Contents/MacOS/\(name)")
        guard FileManager.checked.isExecutableFile(atPath: executable.path) else { return nil }
        return ChromiumHostConfiguration(
            executable: executable,
            arguments: arguments(layout: layout, rootCache: rootCache, bundleIdentifier: bundleIdentifier, environment: environment))
    }

    static func arguments(layout: CEFRuntimeLayout, rootCache: URL, bundleIdentifier: String?,
                          environment: [String: String]) -> [String] {
        // The host refuses a fork below API 30 (kMinForkAPI in chromium_host_wire.h; it exits 66):
        // detached hosting (30) over layer hosting (26) and the resize sync (27). So the switch set
        // is the one for API 27 (no AsyncLiveResize), which every fork the host runs on has.
        let switches = CEFSwitches.current(forkAPIVersion: CEFSwitches.resizeSyncForkAPI,
                                           bundleIdentifier: bundleIdentifier, environment: environment).arguments
            // The host runs Chromium's own message loop: there is no external pump pass to slice.
            .filter { !$0.hasPrefix("cmux-pump-time-slice-us=") }
            // Chromium's code-sign clone copies the main bundle (here the small host app)
            // and starts helpers from the copy, but the helpers live outside it.
            + ["disable-features=MacAppCodeSignClone"]
            + diagnosisSwitches(environment)
        // The main bundle is the app's (as in process), never the host's own small bundle: it holds the
        // framework and the helpers Chromium starts and sandboxes (browser_host_main.mm).
        return ["--framework=\(layout.frameworkDirectory.path)",
                "--subprocess=\(layout.helperExecutable.path)",
                "--main-bundle=\(layout.mainBundle.path)",
                "--root-cache=\(rootCache.path)",
                "--log-file=\(logFile(rootCache: rootCache).path)"]
            + switches.map { "--cef-switch=\($0)" }
    }

    /// Development override (Debug only; a bench build measures the host as it ships, with only the
    /// bench switches of ``CEFSwitches``): more host switches, comma-separated, for diagnosis on a
    /// measure host (chromium-host-bench.py --host-switches: child logging, no-sandbox).
    static func diagnosisSwitches(_ environment: [String: String]) -> [String] {
        #if DEBUG
        return (environment["CMUX_NEXT_CHROMIUM_HOST_SWITCHES"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        #else
        return []
        #endif
    }

    /// Chromium's log of a host whose data folder is `rootCache` (warnings and
    /// fatal messages): where a host that ended says why.
    static func logFile(rootCache: URL) -> URL {
        rootCache.appending(path: "chromium-host.log")
    }

    /// The data folder of this app's host: `<Application Support>/<bundle id>/ChromiumHost`.
    public static func rootCache(applicationSupport: URL, bundleIdentifier: String) -> URL {
        applicationSupport.appending(path: bundleIdentifier).appending(path: "ChromiumHost")
    }

    /// The Crashpad database of a host whose data folder is `rootCache`: browser_host_main.mm points
    /// Chromium's dumps (the host's and its helpers') at `<root cache>/Crashpad` (p01-process task 226).
    public static func crashDatabase(rootCache: URL) -> URL {
        rootCache.appending(path: "Crashpad", directoryHint: .isDirectory)
    }

    /// The `--log-file` this configuration passes, or nil.
    public var logFile: String? {
        arguments.first { $0.hasPrefix("--log-file=") }.map { String($0.dropFirst("--log-file=".count)) }
    }
}
#endif
