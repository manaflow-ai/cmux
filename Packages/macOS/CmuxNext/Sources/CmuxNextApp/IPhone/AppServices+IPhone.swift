import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextMobile
import CmuxNextSettings
import Foundation

extension AppServices {
    /// The cnx service phones and this Mac meet at. `CMUX_NEXT_CNX_API_URL` (a launch
    /// variable; CMUX_NEXT_* survive the launch) points a dev build at another one.
    static let cnxDevelopmentAPI = URL(string: "https://cnx-ios-api-dev.debussy.workers.dev")

    /// Hands the iPhone host what it needs: the bundled hostd, the account's tokens,
    /// this app's daemon socket and acpmux, the chat roots and the computer name.
    func wireIPhoneHost(processEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        let auth = cloud.auth
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/cnx-hostd", isDirectory: false)
        // Dev builds may point at another hostd or service; a release build never does.
        #if DEBUG
        let override = processEnvironment["CMUX_NEXT_CNX_HOSTD_BIN"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let serviceOverride = processEnvironment["CMUX_NEXT_CNX_API_URL"].flatMap { $0.isEmpty ? nil : URL(string: $0) }
        #else
        let override: URL? = nil
        let serviceOverride: URL? = nil
        #endif
        var executable = [override, bundled].compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        // The cnx service accepts the development sign-in project only, for now: a build that
        // signs in to production has no service to register with.
        if auth.configuration.isProductionAuth, serviceOverride == nil { executable = nil }
        let base = serviceOverride ?? Self.cnxDevelopmentAPI
        let namespace = environment.launch.bundleID ?? "com.cmuxterm.app.next"
        let state = DaemonLauncher.applicationSupportDirectory()
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("cnx-host", isDirectory: true)
        guard let base else { return }
        iphone.follow { [weak self] in self?.settings?.snapshot.mobile.allowIPhoneConnections ?? false }
        iphone.dependencies = IPhoneHostService.Dependencies(
            executable: executable,
            baseURL: base,
            stackProjectID: auth.configuration.stackProjectID,
            stateDirectory: state,
            accessToken: { force in
                if force { return try await auth.coordinator.forceRefreshAccessToken() }
                return try await auth.tokens().access
            },
            daemonSocket: { [weak self] in
                guard let self else { throw DaemonError.notConnected }
                return try await self.daemon.endpoint().socketPath
            },
            acpmux: { [weak self] in
                guard let host = await self?.agentTabs.host,
                      let connection = try? await host.handshake(sessionId: nil).connection,
                      connection.remote == nil else { return nil }
                return (connection.url, connection.dashboardToken)
            },
            fileRoots: { [weak self] in
                guard let chats = self?.settings?.chatSettings else { return [] }
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                return (chats.roots + chats.managedRoots).map { $0.hasPrefix("~/") ? home + $0.dropFirst() : $0 }
            },
            computerName: { await MacName.computerName() }
        )
    }

    /// The account the iPhone host registers under: the selected team, else the personal space.
    var iphoneAccount: IPhoneHostService.Account? {
        guard cloud.isSignedIn, let user = cloud.auth.user else { return nil }
        let team = cloud.auth.teamID
        return IPhoneHostService.Account(
            userID: user.id, teamID: CnxHostLaunch.teamID(selected: team, userID: user.id),
            teamName: team.flatMap { id in cloud.auth.teams.first { $0.id == id }?.displayName })
    }
}
