import CMUXAuthCore
public import CmuxNextCompat
public import CmuxNextProcessEnvironment
public import CmuxNextSettings
public import Foundation

/// Who this cmux-next is: bundle, tag, and control socket, derived only from
/// the app's own bundle.
///
/// A cmux-next started from a shell inside another cmux inherits that
/// cmux's `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and `CMUX_TAG`. Trusting them
/// made cmux-next try to bind the user's release socket. So:
///
/// - the socket path comes from the bundle id (and a tag written into the
///   bundle's own `LSEnvironment` by `scripts/reload.sh`), through the
///   build's ``BuildIdentity/controlSocket(userHome:)``, or from the
///   explicit ``socketOverrideKey``;
/// - ``stripInheritedEnvironment()`` removes inherited cmux variables from
///   this process at launch, before anything reads them;
/// - ``terminalEnvironment`` is what this app's terminals must see instead.
public struct LaunchIdentity: Sendable, Equatable {
    /// The only environment variable that picks the control socket path.
    public static let socketOverrideKey = "CMUX_NEXT_SOCKET_PATH"

    public var bundleID: String?
    /// Sanitized tag (`[a-z0-9-]`), nil for untagged builds.
    public var tag: String?
    public var socketPath: String
    /// The socket's old `/tmp` name, kept as a symlink to ``socketPath`` for
    /// tools that still use it (``ControlSocketPath``); nil with an explicit path.
    public var compatibilityLink: String?
    /// The app's own build (bundle id and the tag its bundle ships; never a
    /// DEBUG test override): its daemon session, state and control socket
    /// (``BuildIdentity/appSession``). The `cmux` CLI in this app's terminals
    /// gets the same pair through `CMUX_BUNDLE_ID` and `CMUX_TAG`
    /// (``terminalEnvironment``), so both resolve one build.
    public var build: BuildIdentity

    public init(bundleID: String?, tag: String?, socketPath: String, compatibilityLink: String? = nil,
                build: BuildIdentity? = nil) {
        self.bundleID = bundleID
        self.tag = tag
        self.socketPath = socketPath
        self.compatibilityLink = compatibilityLink
        self.build = build ?? BuildIdentity(bundleID: bundleID, bundledTag: tag)
    }

    /// Variables every terminal of this app gets, so the `cmux` CLI inside
    /// it talks to this app and never to the cmux that launched it.
    public var terminalEnvironment: [String: String] {
        var environment = ["CMUX_SOCKET_PATH": socketPath]
        if let bundleID { environment["CMUX_BUNDLE_ID"] = bundleID }
        // The build's tag (the shipped one first), so the CLI's build key is
        // this app's even for a copy that ships another tag than its id.
        if let tag = build.tag ?? tag { environment["CMUX_TAG"] = tag }
        if let space = buildSpaceValue { environment[Self.buildSpaceKey] = space }
        return environment
    }

    /// The variable that tells every Rust child of this app its cloud build space (cmux-tui
    /// `cmux-build-space`): `dev:<slug>` for a tagged dev build, unset for nightly and stable.
    public static let buildSpaceKey = "CMUX_BUILD_SPACE"

    /// This build's `CMUX_BUILD_SPACE` for its children (``CMUXBuildSpaceState/childEnvironmentValue``): its space
    /// for a tagged dev build, nil for nightly and stable, and a refusing value for a dev build with no usable tag.
    public var buildSpaceValue: String? { Self.childBuildSpace(build) }

    static func childBuildSpace(_ build: BuildIdentity) -> String? {
        CMUXBuildSpaceState(devBuild: build.needsBuildSpace, devTag: build.devTag).childEnvironmentValue
    }

    /// Pure resolution. `bundledEnvironment` is the bundle's own
    /// `Info.plist` `LSEnvironment`; `processEnvironment` is consulted only
    /// for ``socketOverrideKey``.
    public static func resolve(
        bundleID: String?,
        bundledEnvironment: [String: String],
        processEnvironment: [String: String],
        isDebugBuild: Bool,
        bundleName: String? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> LaunchIdentity {
        let bundle = bundleID.flatMap { $0.isEmpty ? nil : $0 }
        // The tag the bundle ships; a copy named `cmux DEV <tag>.app` that
        // lost `LSEnvironment` ships its name's tag (the `cmux` CLI reads the
        // bundle the same way: cmux-tui app_identity.rs).
        let shipped = bundledEnvironment["CMUX_TAG"].flatMap(ControlSocketPath.shared.sanitize) ?? taggedAppName(bundleName)
        let tag = ControlSocketPath.shared.bundleTag(bundle) ?? shipped
        let build = BuildIdentity(bundleID: bundle, bundledTag: shipped)
        if let explicit = processEnvironment[socketOverrideKey]?.trimmingCharacters(in: .whitespaces), !explicit.isEmpty {
            return LaunchIdentity(bundleID: bundle, tag: tag, socketPath: explicit, build: build)
        }
        let paths = ControlSocketPath.shared
        // The build's own socket name (per-build isolation S3), in the state
        // folder with its old /tmp name as a link. A DEBUG compile under
        // release's bundle id never takes release's socket.
        let named = isDebugBuild && build.kind == .release ? nil : build.controlSocket(userHome: home)
        let socket = named.map { paths.moved($0, home: home) }
            ?? (path: paths.resolve(bundleID: nil, tag: nil, isDebugBuild: isDebugBuild, home: home),
                link: paths.compatibilityLink(bundleID: nil, tag: nil, isDebugBuild: isDebugBuild, home: home))
        return LaunchIdentity(bundleID: bundle, tag: tag, socketPath: socket.path, compatibilityLink: socket.link, build: build)
    }

    /// A fleet artifact is sometimes launched directly from its staged
    /// `cmux DEV <tag>.app` path instead of through LaunchServices. Keep the
    /// tag in that case even when the copied Info.plist lost LSEnvironment.
    private static func taggedAppName(_ name: String?) -> String? {
        guard let name, name.hasPrefix("cmux DEV ") else { return nil }
        return ControlSocketPath.shared.sanitize(String(name.dropFirst("cmux DEV ".count)))
    }

    /// Variables only another cmux sets in its terminals and agents: when one
    /// of them is inherited (not from this bundle's `LSEnvironment`), another
    /// cmux started this process.
    public static let otherCmuxMarkers = ["CMUX_SOCKET_PATH", "CMUX_BUNDLE_ID", "CMUX_TAG", "MUX_AGENT_TOKEN_FILE"]

    /// The `CMUX_NEXT_*` knobs that name a state root (Chief home, acpmux
    /// home, control socket, settings file). A test harness or a person sets
    /// them on purpose; inherited from another cmux they are that build's
    /// roots (per-build isolation S4, cx-is1kf.5).
    public static let stateRootKnobs = ["CHIEF_HOME", "CHIEF_ROOT", "CHIEF_BUILD_ID", "CHIEF_ACCOUNT",
                                        "MUX_HOME", "ACPMUX_ROOT", "SOCKET_PATH", "CONFIG_FILE",
                                        "CLOUD_SECRETS_FILE", "CLOUD_SECRETS_SERVICE", "KEYS_AUDIT_FILE",
                                        "MCP_UPSTREAMS_DIR", "MUX_PLUGINS_DIR", "CLASSIC_IMPORT_DIR",
                                        "SETTINGS_BUILD_DEFAULTS"].map { "CMUX_NEXT_" + $0 }

    /// The Cloud selection an app exports to its own terminals once its Cloud bootstrap resolves (AppDelegate):
    /// the `cmux` CLI there reads them as that app's backend. A person or a script may set them on purpose to
    /// seed a launch (`cloud env get`, docs/cmux-next/cloud-environments.md); inherited from another cmux they
    /// are that app's selection, and a DEV build opened from a NIGHTLY terminal took the nightly's production
    /// backend and came up signed out. `--cloud-backend NAME` is the launch override that works from anywhere.
    public static let cloudSelectionKnobs = ["CMUX_NEXT_CLOUD_RUNTIME", "CMUX_NEXT_CLOUD_ENV", "CMUX_NEXT_CLOUD_BACKEND"]

    /// The capture shell home (`AppEnvironment.captureShellHome`): a PR capture slot names it in the
    /// clone's `LSEnvironment`, and a DEBUG launch may pass it in its environment instead (the media
    /// tours, scripts/cmux-next/media/tour.py), so the tour's shells and machine labels name no CI Mac.
    public static let captureShellHomeKey = "CMUX_CAPTURE_SHELL_HOME"

    /// The live code folder (`LiveCode.fromEnvironment`): a side instance names it in the copy's
    /// `LSEnvironment`, and a harness passes it in its environment instead (the live code proof,
    /// scripts/measure/live-code-app.py). Only a debug, bench or live code build reads it.
    public static let liveCodeDirKey = "CMUX_LIVE_CODE_DIR"

    /// A launch that ignores every customization layer for this run, editing no file: the way back
    /// when the UI itself is broken (`open -a "cmux NIGHTLY" --args --no-customizations`, or
    /// `CMUX_NO_CUSTOMIZATIONS=1`). Leo, 2026-11-14: "I want people to not accidentally soft lock
    /// themselves and like have good recovery options or whatever".
    public static let noCustomizationsKey = "CMUX_NO_CUSTOMIZATIONS"
    public static let noCustomizationsArgument = "--no-customizations"

    /// Whether this launch ignores every layer: the argument, the variable set to anything but
    /// empty, `0`, `false` or `no`, or Option and Shift held as the app starts (`keysHeld`).
    public static func ignoresCustomizations(arguments: [String] = ProcessInfo.processInfo.arguments,
                                             environment: [String: String] = ProcessInfo.processInfo.environment,
                                             keysHeld: Bool = false) -> Bool {
        if keysHeld || arguments.dropFirst().contains(noCustomizationsArgument) { return true }
        guard let raw = environment[noCustomizationsKey]?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return !["", "0", "false", "no"].contains(raw)
    }

    /// Keys of cmux variables this process inherited rather than received
    /// from its own bundle: every `CMUX*` but the `CMUX_NEXT_*` launch knobs,
    /// ``liveCodeDirKey``, ``noCustomizationsKey`` (and, in a DEBUG build, ``captureShellHomeKey``).
    /// When another cmux started this process (``otherCmuxMarkers``), also
    /// the ``stateRootKnobs`` and that build's files (``BuildStatePaths/environmentKeys``), every `MUX_*` but `MUX_HARNESS`, and every
    /// `OPTCHAT_*`: that build's Chief, brain and acpmux roots. Its
    /// ``cloudSelectionKnobs`` go too, unless the inherited `CMUX_BUNDLE_ID`
    /// is `bundleID`: a launcher that names this app sets them for this app.
    public static func inheritedKeys(processEnvironment: [String: String], bundledEnvironment: [String: String],
                                     bundleID: String? = nil,
                                     isDebugBuild: Bool = ControlService.isDebugBuild) -> [String] {
        let inherited = { (key: String) in processEnvironment[key].map { bundledEnvironment[key] != $0 } ?? false }
        let fromOtherCmux = otherCmuxMarkers.contains(where: inherited)
        let namesThisApp = bundleID.map { !$0.isEmpty && processEnvironment["CMUX_BUNDLE_ID"] == $0 } ?? false
        return processEnvironment.keys.filter { key in
            guard inherited(key) else { return false }
            if key == captureShellHomeKey, isDebugBuild, !fromOtherCmux { return false }
            if key == liveCodeDirKey || key == noCustomizationsKey, !fromOtherCmux { return false }
            if cloudSelectionKnobs.contains(key) { return fromOtherCmux && !namesThisApp }
            if key.hasPrefix("CMUX_NEXT_") { return fromOtherCmux && stateRootKnobs.contains(key) }
            if key.hasPrefix("CMUX") { return true }
            guard fromOtherCmux else { return false }
            // A DEV build's files (BuildStatePaths) that carry no cmux prefix: that build's host budget.
            if BuildStatePaths.environmentKeys.contains(key) { return true }
            return (key.hasPrefix("MUX_") && key != "MUX_HARNESS") || key.hasPrefix("OPTCHAT_")
        }
    }

    /// The bundle's `LSEnvironment`, which LaunchServices copies into the
    /// process environment. Values that match it are this app's own.
    public static func bundledEnvironment(_ bundle: Bundle = .main) -> [String: String] {
        (bundle.object(forInfoDictionaryKey: "LSEnvironment") as? [String: Any] ?? [:])
            .compactMapValues { $0 as? String }
    }

    /// This process's identity. Call ``stripInheritedEnvironment()`` first.
    public static func current(bundle: Bundle = .main, isDebugBuild: Bool = ControlService.isDebugBuild) -> LaunchIdentity {
        resolve(
            bundleID: bundle.bundleIdentifier,
            bundledEnvironment: bundledEnvironment(bundle),
            processEnvironment: ProcessInfo.processInfo.environment,
            isDebugBuild: isDebugBuild,
            bundleName: bundle.bundleURL.deletingPathExtension().lastPathComponent
        )
    }

    /// Unsets inherited cmux variables in this process. Run first thing in
    /// `main`, before any thread starts and before the environment freeze
    /// (``ProcessEnvironmentGuard``). Returns the removed keys.
    ///
    /// `settingsBuildDefaults` are this build's (`SettingsBuildDefaults.thisBuild`): their
    /// ``BuildStatePaths/settingsBuildDefaultsKey`` value is set for the Rust settings owner; none unsets one
    /// inherited from another build.
    @discardableResult
    public static func stripInheritedEnvironment(
        bundle: Bundle = .main,
        statePaths: BuildStatePaths = .current,
        settingsBuildDefaults: SettingsBuildDefaults = .none,
        environmentGuard: ProcessEnvironmentGuard = .process
    ) -> [String] {
        let bundled = bundledEnvironment(bundle)
        let process = ProcessInfo.processInfo.environment
        let keys = inheritedKeys(processEnvironment: process, bundledEnvironment: bundled, bundleID: bundle.bundleIdentifier)
        // This build's own space replaces any inherited one, so every Rust child that inherits
        // this environment (the `cmux` CLI runs, `cmux link`, the Codex holder, acpmux) sends it.
        let space = childBuildSpace(BuildIdentity(bundle: bundle))
        let defaults = settingsBuildDefaults.childEnvironmentValue
        // A build without settings defaults never passes on another build's.
        let unset = defaults == nil && process[BuildStatePaths.settingsBuildDefaultsKey] != nil
            ? keys + [BuildStatePaths.settingsBuildDefaultsKey] : keys
        environmentGuard.write("LaunchIdentity.stripInheritedEnvironment") {
            for key in unset { unsetenv(key) }
            // Then this build's own values: its space, and for a DEV build its own settings file and the
            // files beside it (``BuildStatePaths``; nothing for NIGHTLY or stable), read over what is left, so an
            // explicit override the launch passed (a harness's CMUX_NEXT_CONFIG_FILE) still wins.
            var values: [String: String] = statePaths.launchEnvironment(over: ProcessInfo.processInfo.environment)
            if let space { values[buildSpaceKey] = space }
            if let defaults { values[BuildStatePaths.settingsBuildDefaultsKey] = defaults }
            for (key, value) in values { setenv(key, value, 1) }
        }
        return keys.sorted()
    }
}
