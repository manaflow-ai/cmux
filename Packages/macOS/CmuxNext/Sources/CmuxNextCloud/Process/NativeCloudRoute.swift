import Foundation

/// The app-owned Native link for one selected team and mesh. Enrollment and
/// the child broker stay together so a team switch can stop both atomically.
package actor NativeCloudRoute {
    private let enrollment: NativeDeviceEnrollment
    private let child: NativeCloudLinkChild

    private init(enrollment: NativeDeviceEnrollment, child: NativeCloudLinkChild) {
        self.enrollment = enrollment
        self.child = child
    }

    /// Resolves the selected team's authoritative Native target, enrolls this
    /// install into that mesh, then starts the verified cmux-tui child. The
    /// child receives only the private broker channel; install credentials
    /// never enter its environment or argv.
    package static func make(team: String, mesh: String? = nil, identity: MacInstallIdentity,
                             paths: CloudPaths, session: @escaping InstallAuthClient.SessionToken,
                             deviceName: String, bundle: Bundle, directory: URL, home: URL) async throws -> Self {
        let target = try await identity.nativeNetworkTarget(team: team, mesh: mesh)
        let enrollment = try NativeDeviceEnrollment(scope: target.scope, identity: identity, paths: paths,
                                                     native: NativeDeviceHTTPTransport(origin: target.origin), session: session,
                                                     name: deviceName)
        let publisher = try NativeCloudExecutable.Publisher.current()
        let child = NativeCloudLinkChild(bundleURL: bundle.bundleURL, publisher: publisher, directory: directory, home: home,
                                         prepare: { try await enrollment.linkStartup() },
                                         reply: { try await enrollment.cloudBrokerReply($0) })
        return Self(enrollment: enrollment, child: child)
    }

    package func ensure() async throws -> NativeCloudLinkChild.Ready { try await child.ensure() }
    package func socketPath() async throws -> String { try await child.socketPath() }
    /// Stop the child while retaining the enrollment for a later policy
    /// resume. A final archive calls ``revoke()`` and discards it.
    package func suspend() async { await child.stop() }
    package func stop() async { await child.stop(); await enrollment.stop() }
    package func revoke() async throws { await child.stop(); try await enrollment.revoke() }
}
