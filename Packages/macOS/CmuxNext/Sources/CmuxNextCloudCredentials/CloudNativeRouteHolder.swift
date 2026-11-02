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
        guard let team = MacInstallIdentity.team(ofToken: token) else { throw NativeDeviceEnrollmentError.invalidIdentity }
        if route == nil || routeTeam != team {
            try await route?.revoke()
            let auth = auth
            let created = try await NativeCloudRoute.make(team: team, identity: identity, paths: paths,
                                                           session: { [auth] in try await auth.tokens().access },
                                                           deviceName: deviceName, bundle: bundle,
                                                           directory: directory, home: FileManager.default.homeDirectoryForCurrentUser)
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


/// The app server link of a non-production build: the Native device route first, and this Mac's
/// `cmux link` for an install whose Native route fails (a team the development Worker has no Native
/// mesh for answers 400), so turning Native on never leaves such a team with no machine. The fallback
/// holds until sign-out (``archive(install:)``), and `onFallback` says why it was taken.
@MainActor
public final class CloudNativeFirstLauncher: CloudLinkLaunching {
    private let native: any CloudLinkLaunching
    private let link: (any CloudLinkLaunching)?
    private let onFallback: (any Error) -> Void
    private var usingLink = false

    public init(native: any CloudLinkLaunching, link: (any CloudLinkLaunching)?,
                onFallback: @escaping (any Error) -> Void = { _ in }) {
        self.native = native; self.link = link; self.onFallback = onFallback
    }

    public func ensure(install: String) async throws -> CloudLinkLauncher.Ensured {
        if usingLink, let link { return try await link.ensure(install: install) }
        do {
            return try await native.ensure(install: install)
        } catch {
            // Signed out or cancelled is not a route failure: the link would refuse the same way.
            guard let link, !(error is CancellationError),
                  error as? NativeDeviceEnrollmentError != .signedOut else { throw error }
            onFallback(error)
            usingLink = true
            await native.archive(install: install)
            return try await link.ensure(install: install)
        }
    }

    public func stop(install: String?) async {
        if usingLink { await link?.stop(install: install) } else { await native.stop(install: install) }
    }

    public func archive(install: String?) async {
        await native.archive(install: install)
        await link?.archive(install: install)
        usingLink = false
    }
}
