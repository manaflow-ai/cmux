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
        ["--framework=\(layout.frameworkDirectory.path)",
         "--subprocess=\(layout.helperExecutable.path)",
         "--root-cache=\(rootCache.path)"]
            + switches(bundleIdentifier: bundleIdentifier, environment: environment).map { "--cef-switch=\($0)" }
    }

    /// Features the host turns on beyond the app's switch set.
    /// `TimerSlackMac` gives each delayed task's leeway to the run loop timer
    /// (`MessagePumpCFRunLoopBase::ScheduleDelayedWork` calls
    /// `CFRunLoopTimerSetTolerance` first, base/message_loop/message_pump_apple.mm;
    /// the feature is in base/task/task_features.h). The host runs `CefRunMessageLoop`,
    /// Chromium's own pump, so this is Chrome's timer model. The app's UI thread
    /// waits for the absolute-time fork callback (p14-energy-046): its external
    /// pump gets whole milliseconds and would lose the 8 ms wake alignment.
    static let enabledFeatures = ["TimerSlackMac"]
    /// Chromium's code-sign clone copies the main bundle (here the small host app)
    /// and starts helpers from the copy, but the helpers live outside it.
    static let disabledFeatures = ["MacAppCodeSignClone"]

    /// The app's Chromium switches (wake alignment, the idle disables) with the
    /// host's own features merged in: one entry per feature-list switch.
    static func switches(bundleIdentifier: String?, environment: [String: String]) -> [String] {
        // The host refuses a fork without layer hosting, so the switch set is the one for
        // the resize-sync fork API (no AsyncLiveResize).
        let app = CEFSwitches.current(forkAPIVersion: CEFSwitches.resizeSyncForkAPI,
                                      bundleIdentifier: bundleIdentifier, environment: environment).arguments
            // The host runs Chromium's own message loop: there is no external pump pass to slice.
            .filter { !$0.hasPrefix("cmux-pump-time-slice-us=") }
        let enabled = mergingFeatureList("enable-features", adding: enabledFeatures, into: app)
        return mergingFeatureList("disable-features", adding: disabledFeatures, into: enabled)
    }

    /// `switches` with every `name=` entry and `added` joined into one entry at
    /// the first one's place (at the end when there is none): the features in
    /// order, each once. The host merges this entry into CEF's own list
    /// (CEFShim/src/command_line_switches.h).
    static func mergingFeatureList(_ name: String, adding added: [String], into switches: [String]) -> [String] {
        let prefix = name + "="
        var features: [String] = []
        var result: [String] = []
        var slot: Int?
        for entry in switches {
            guard entry.hasPrefix(prefix) else {
                result.append(entry)
                continue
            }
            if slot == nil {
                slot = result.count
                result.append(entry)
            }
            features += entry.dropFirst(prefix.count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        var seen = Set<String>()
        let merged = (features + added).filter { !$0.isEmpty && seen.insert($0).inserted }
        switch (slot, merged.isEmpty) {
        case (let slot?, false): result[slot] = prefix + merged.joined(separator: ",")
        case (let slot?, true): result.remove(at: slot)
        case (nil, false): result.append(prefix + merged.joined(separator: ","))
        case (nil, true): break
        }
        return result
    }
}
