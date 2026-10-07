public import Foundation

/// Who this cmux-next is: bundle, tag, and control socket, derived only from
/// the app's own bundle.
///
/// A cmux-next started from a shell inside another cmux inherits that
/// cmux's `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and `CMUX_TAG`. Trusting them
/// made cmux-next try to bind the user's release socket. So:
///
/// - the socket path comes from the bundle id (and a tag written into the
///   bundle's own `LSEnvironment` by `scripts/reload.sh`), or from the
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

    public init(bundleID: String?, tag: String?, socketPath: String) {
        self.bundleID = bundleID
        self.tag = tag
        self.socketPath = socketPath
    }

    /// Variables every terminal of this app gets, so the `cmux` CLI inside
    /// it talks to this app and never to the cmux that launched it.
    public var terminalEnvironment: [String: String] {
        var environment = ["CMUX_SOCKET_PATH": socketPath]
        if let bundleID { environment["CMUX_BUNDLE_ID"] = bundleID }
        if let tag { environment["CMUX_TAG"] = tag }
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
        let tag = ControlSocketPath.shared.bundleTag(bundle)
            ?? bundledEnvironment["CMUX_TAG"].flatMap(ControlSocketPath.shared.sanitize)
            ?? taggedAppName(bundleName)
        var path = ControlSocketPath.shared.resolve(bundleID: bundle, tag: tag, isDebugBuild: isDebugBuild, home: home)
        if let explicit = processEnvironment[socketOverrideKey]?.trimmingCharacters(in: .whitespaces), !explicit.isEmpty {
            path = explicit
        }
        return LaunchIdentity(bundleID: bundle, tag: tag, socketPath: path)
    }

    /// A fleet artifact is sometimes launched directly from its staged
    /// `cmux DEV <tag>.app` path instead of through LaunchServices. Keep the
    /// tag in that case even when the copied Info.plist lost LSEnvironment.
    private static func taggedAppName(_ name: String?) -> String? {
        guard let name, name.hasPrefix("cmux DEV ") else { return nil }
        return ControlSocketPath.shared.sanitize(String(name.dropFirst("cmux DEV ".count)))
    }

    /// Keys of cmux variables this process inherited rather than received
    /// from its own bundle. `CMUX_NEXT_*` launch knobs stay.
    public static func inheritedKeys(processEnvironment: [String: String], bundledEnvironment: [String: String]) -> [String] {
        processEnvironment.compactMap { key, value in
            guard key.hasPrefix("CMUX"), !key.hasPrefix("CMUX_NEXT_") else { return nil }
            return bundledEnvironment[key] == value ? nil : key
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
    /// `main`, before any thread starts. Returns the removed keys.
    @discardableResult
    public static func stripInheritedEnvironment(bundle: Bundle = .main) -> [String] {
        let keys = inheritedKeys(processEnvironment: ProcessInfo.processInfo.environment,
                                 bundledEnvironment: bundledEnvironment(bundle))
        for key in keys { unsetenv(key) }
        return keys.sorted()
    }
}
