public import CmuxNextCloud
public import CmuxNextDaemon
public import CmuxNextCompat
public import Foundation

@MainActor
public final class CloudNativeRouteHolder: CloudLinkLaunching {
    private let identity: MacInstallIdentity
    private let auth: CloudAuth
    private let paths: CloudPaths
    private let bundle: Bundle
    private let directory: URL
    private let deviceName: String
    private var route: NativeCloudRoute?
    private var routeTeam: String?

    private init(identity: MacInstallIdentity, auth: CloudAuth, paths: CloudPaths, directory: URL, deviceName: String,
         bundle: Bundle = .main) {
        self.identity = identity; self.auth = auth; self.paths = paths; self.directory = directory; self.bundle = bundle; self.deviceName = deviceName
    }

    public static func forApp(identity: MacInstallIdentity, auth: CloudAuth, paths: CloudPaths,
                              build: BuildIdentity, deviceName: String, bundle: Bundle = .main) -> CloudNativeRouteHolder? {
        guard let directory = CloudLinkLauncher.forApp(bundle: bundle, build: build)?.stateDirectory else { return nil }
        return CloudNativeRouteHolder(identity: identity, auth: auth, paths: paths, directory: directory,
                                      deviceName: deviceName, bundle: bundle)
    }

    public func ensure(install: String) async throws -> CloudLinkLauncher.Ensured {
        guard auth.isSignedIn else { throw NativeDeviceEnrollmentError.signedOut }
        // The selection is a Stack ID; Native APIs take the authenticated Worker's team ID.
        let token = try await identity.installToken()
        guard let team = MacInstallIdentity.team(ofToken: token) else { throw NativeDeviceEnrollmentError.identity() }
        if route == nil || routeTeam != team {
            try await route?.revoke()
            let auth = auth
            let created = try await NativeCloudRoute.make(team: team, identity: identity, paths: paths,
                                                           session: { [auth] in try await auth.tokens().access },
                                                           deviceName: deviceName, bundle: bundle,
                                                           directory: directory, home: FileManager.default.homeDirectoryForCurrentUser,
                                                           temporaryDirectory: DaemonLauncher.userTemporaryDirectory())
            route = created
            routeTeam = team
        }
        guard let route else { throw NativeDeviceEnrollmentError.invalidState }
        let ready = try await route.ensure()
        return CloudLinkLauncher.Ensured(status: ready.status, pid: ready.pid, socket: ready.socket)
    }

    public func stop(install: String?) async { await route?.suspend() }

    public func archive(install: String?) async {
        do { try await route?.revoke() }
        catch { }
        route = nil
        routeTeam = nil
    }
}


/// The app server link's Native device route, the default (`CMUX_NEXT_CLOUD_NATIVE_LINK=0` turns it off),
/// with this Mac's `cmux link` for an install whose Native route fails to start (a team the Worker has no
/// Native mesh for answers 400), so Native never leaves such a team with no machine. The fallback holds for
/// `retryNativeAfter` (doubling after each failed retry, up to 15 min), then the next `ensure` stops the link
/// (the two share one state folder and its lock) and tries Native again: a new team has no mesh until its first machine
/// is made, and that happens after the link first starts, so a fallback held until sign-out (``archive(install:)``)
/// would never reach that machine. `onFallback` says why each fallback was taken. Native is the default because it
/// is the only route that reaches a Worker machine today: `connect_info` answers no gateway, VPC endpoint or
/// public address, so `cmux link` over the relay finds no route to any machine ("refused the dial:
/// unreachable"), while a vm-api machine's Native network routes through the enrolled mesh tunnel.
@MainActor
public final class CloudNativeFirstLauncher: CloudLinkLaunching {
    private let native: any CloudLinkLaunching
    private let link: (any CloudLinkLaunching)?
    private let onFallback: (any Error) -> Void
    private let retryNativeAfter: Duration
    /// When the link took over; nil while Native is in use.
    private var linkSince: ContinuousClock.Instant?
    /// Native failures in a row: each doubles the hold before the next try.
    private var failures = 0
    private static let longestHold: Duration = .seconds(15 * 60)
    private var hold: Duration {
        min(retryNativeAfter * (1 << min(max(failures - 1, 0), 10)), max(retryNativeAfter, Self.longestHold))
    }
    private var usingLink: Bool { linkSince != nil }
    /// Why the Native route did not start, when the link took over (for `cloud.machines`' `link_route`).
    public private(set) var fallbackReason: String?
    /// The route in use: `native`, or `link` with the Native failure that made the link take over.
    public var route: String { usingLink ? "link (native failed: \(fallbackReason ?? "unknown"))" : "native" }

    public enum Choice: Equatable, Sendable { case native, link }

    /// `CMUX_NEXT_CLOUD_NATIVE_LINK` in the bundle's LSEnvironment or the launch environment
    /// (CMUX_NEXT_* survives LaunchIdentity's strip).
    public nonisolated static var setting: String? {
        let key = "CMUX_NEXT_CLOUD_NATIVE_LINK"
        let bundled = Bundle.main.object(forInfoDictionaryKey: "LSEnvironment") as? [String: String]
        return bundled?[key] ?? ProcessInfo.processInfo.environment[key]
    }

    /// Which route the app server link takes: `=0` `cmux link`, anything else (unset included) Native first.
    public nonisolated static func choice(setting: String? = CloudNativeFirstLauncher.setting) -> Choice {
        setting == "0" ? .link : .native
    }

    public init(native: any CloudLinkLaunching, link: (any CloudLinkLaunching)?,
                retryNativeAfter: Duration = .seconds(60), onFallback: @escaping (any Error) -> Void = { _ in }) {
        self.native = native; self.link = link; self.retryNativeAfter = retryNativeAfter; self.onFallback = onFallback
    }

    public func ensure(install: String) async throws -> CloudLinkLauncher.Ensured {
        if let since = linkSince, let link {
            if ContinuousClock.now - since < hold { return try await link.ensure(install: install) }
            // The Native child serves from the link's state folder, which a running link holds locked.
            await link.stop(install: install)
        }
        do {
            let ensured = try await native.ensure(install: install)
            linkSince = nil
            fallbackReason = nil
            failures = 0
            return ensured
        } catch {
            // Signed out or cancelled is not a route failure: the link would refuse the same way.
            guard let link, !(error is CancellationError),
                  error as? NativeDeviceEnrollmentError != .signedOut else { throw error }
            onFallback(error)
            fallbackReason = String(describing: error)
            linkSince = ContinuousClock.now
            failures += 1
            // Stop, never revoke: the retry reuses this enrollment, since the server keeps one host network
            // binding per install and refuses to retarget it to a new device ("cannot be retargeted").
            await native.stop(install: install)
            return try await link.ensure(install: install)
        }
    }

    public func stop(install: String?) async {
        if usingLink { await link?.stop(install: install) } else { await native.stop(install: install) }
    }

    public func archive(install: String?) async {
        await native.archive(install: install)
        await link?.archive(install: install)
        linkSince = nil
        failures = 0
    }
}
