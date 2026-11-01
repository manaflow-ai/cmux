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

