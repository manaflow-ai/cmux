public import CmuxNextCompat
public import CmuxNextProcessEnvironment
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
        return environment
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
                                        "MUX_HOME", "ACPMUX_ROOT", "SOCKET_PATH", "CONFIG_FILE"].map { "CMUX_NEXT_" + $0 }

    /// The capture shell home (`AppEnvironment.captureShellHome`): a PR capture slot names it in the
    /// clone's `LSEnvironment`, and a DEBUG launch may pass it in its environment instead (the media
    /// tours, scripts/cmux-next/media/tour.py), so the tour's shells and machine labels name no CI Mac.
    public static let captureShellHomeKey = "CMUX_CAPTURE_SHELL_HOME"

    /// Keys of cmux variables this process inherited rather than received
    /// from its own bundle: every `CMUX*` but the `CMUX_NEXT_*` launch knobs
    /// (and, in a DEBUG build, ``captureShellHomeKey``).
    /// When another cmux started this process (``otherCmuxMarkers``), also
    /// the ``stateRootKnobs``, every `MUX_*` but `MUX_HARNESS`, and every
    /// `OPTCHAT_*`: that build's Chief, brain and acpmux roots.
    public static func inheritedKeys(processEnvironment: [String: String], bundledEnvironment: [String: String],
                                     isDebugBuild: Bool = ControlService.isDebugBuild) -> [String] {
        let inherited = { (key: String) in processEnvironment[key].map { bundledEnvironment[key] != $0 } ?? false }
        let fromOtherCmux = otherCmuxMarkers.contains(where: inherited)
        return processEnvironment.keys.filter { key in
            guard inherited(key) else { return false }
            if key == captureShellHomeKey, isDebugBuild, !fromOtherCmux { return false }
            if key.hasPrefix("CMUX_NEXT_") { return fromOtherCmux && stateRootKnobs.contains(key) }
            if key.hasPrefix("CMUX") { return true }
            guard fromOtherCmux else { return false }
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
    @discardableResult
    public static func stripInheritedEnvironment(
        bundle: Bundle = .main,
        environmentGuard: ProcessEnvironmentGuard = .process
    ) -> [String] {
        let keys = inheritedKeys(processEnvironment: ProcessInfo.processInfo.environment,
                                 bundledEnvironment: bundledEnvironment(bundle))
        environmentGuard.write("LaunchIdentity.stripInheritedEnvironment") {
            for key in keys { unsetenv(key) }
        }
        return keys.sorted()
    }
}
