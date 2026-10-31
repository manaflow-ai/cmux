public import CmuxNextAgentPane
public import CmuxNextCloud
import CmuxNextDaemon
public import CmuxNextDaemonService
public import CmuxNextMobile
public import CmuxNextSettings
public import Foundation

extension IPhoneHostService {
    /// The mobile service phones and this Mac meet at: production for production sign-in, the dev
    /// Worker for development sign-in. `CMUX_NEXT_MOBILE_API_URL` (a launch variable; CMUX_NEXT_*
    /// survive the launch) points a Debug build at another one.
    static let productionAPI = URL(string: "https://mobile-api.cmux.dev")
    static let developmentAPI = URL(string: "https://cmux-mobile-api-dev.debussy.workers.dev")

    /// Hands the host what it needs from the app: the bundled hostd, the account's tokens,
    /// the app's daemon socket and acpmux, the chat roots, the computer name, and the
    /// `mobile.allowIPhoneConnections` setting it follows.
    ///
    /// - Parameters:
    ///   - auth: The app's Stack session; tokens are read per request, never stored here.
    ///   - daemon: The app's local daemon; hostd splices phones to its socket.
    ///   - acpmuxHost: The agent tabs' acpmux host (started on first use).
    ///   - agentTabHost: This Mac's agent tab host (`install:<id>`), for agent tabs a phone creates.
    ///   - settings: The settings controller (the toggle and the chat roots).
    ///   - bundleID: The app's bundle id: hostd's state folder is per bundle.
    ///   - computerName: How phones list this Mac.
    ///   - processEnvironment: Read for the Debug-only overrides.
    ///   - acpmuxEnvironment: The app's acpmux, for the phones' approval keys (nil: none).
    ///   - chief: This app's Chief owner (session, and socket once connected), which hostd serves to phones.
    ///   - surfaceHosts: The app's phone tabs as streamed simulator surfaces (nil: this Mac streams none).
    public func wire(auth: CloudAuth, daemon: DaemonService,
                     acpmuxHost: @escaping @MainActor @Sendable () -> (any AgentPaneHostProviding)?,
                     acpmuxEnvironment: AcpmuxEnvironment? = nil,
                     agentTabHost: @escaping @MainActor () -> String? = { nil },
                     newChatPicks: @escaping @MainActor @Sendable () -> NewChatPicks = { NewChatPicks() },
                     chief: (@MainActor () async -> ChiefPlacement?)? = nil,
                     surfaceHosts: (any MobileHostSurfaceHosting)? = nil,
                     settings: @escaping @MainActor @Sendable () -> SettingsController?,
                     bundleID: String?, computerName: @escaping @Sendable () async -> String,
                     processEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux-mobile-host", isDirectory: false)
        // Debug builds may point at another hostd or service; a release build never does.
        #if DEBUG
        let override = processEnvironment["CMUX_NEXT_MOBILE_HOST_BIN"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let serviceOverride = processEnvironment["CMUX_NEXT_MOBILE_API_URL"].flatMap { $0.isEmpty ? nil : URL(string: $0) }
        // The name phones list this Mac by (the multimac rig gives two Macs one name: a
        // name must never make the phone treat them as one).
        let nameOverride = processEnvironment["CMUX_NEXT_MOBILE_DEVICE_NAME"].flatMap { $0.isEmpty ? nil : $0 }
        #else
        let override: URL? = nil
        let serviceOverride: URL? = nil
        let nameOverride: String? = nil
        #endif
        let executable = [override, bundled].compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        // Each Worker accepts only its own sign-in project's tokens.
        guard let base = serviceOverride ?? (auth.configuration.isProductionAuth ? Self.productionAPI : Self.developmentAPI) else { return }
        let state = MobileHostStateDirectory(parent: DaemonLauncher.applicationSupportDirectory()
            .appendingPathComponent(bundleID ?? "com.cmuxterm.app.next", isDirectory: true)).resolve()
        // The phone's browser tabs stream from this build's own remote browser host
        // (Contents/Helpers, every configuration on arm64).
        let browserHosts: (any MobileHostBrowserHosting)? = IPhoneBrowserHosts.available()
            ? IPhoneBrowserHosts(workRoot: state.appendingPathComponent("browser", isDirectory: true)) : nil
        follow { settings()?.snapshot.mobile.allowIPhoneConnections ?? false }
        defer {
            followWorkspaceFolders()
            followNewChatPicks()
        }
        followAccount { Self.account(of: auth, signedIn: auth.isSignedIn) }
        dependencies = Dependencies(
            executable: executable,
            baseURL: base,
            stackProjectID: auth.configuration.stackProjectID,
            stateDirectory: state,
            accessToken: { force in
                if force { return try await auth.coordinator.forceRefreshAccessToken() }
                return try await auth.tokens().access
            },
            daemonSocket: { [weak daemon] in
                guard let daemon else { throw DaemonError.notConnected }
                return try await daemon.endpoint().socketPath
            },
            acpmux: {
                guard let host = await acpmuxHost(),
                      let connection = try? await host.handshake(sessionId: nil).connection,
                      connection.remote == nil else { return nil }
                return (connection.url, connection.dashboardToken)
            },
            fileRoots: {
                guard let chats = settings()?.chatSettings else { return [] }
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                return (chats.roots + chats.managedRoots).map { $0.hasPrefix("~/") ? home + $0.dropFirst() : $0 }
            },
            workspaceFolders: { [weak daemon] in
                var folders: [String] = []
                for workspace in daemon?.store.workspaces ?? [] {
                    for screen in workspace.screens {
                        for pane in screen.panes {
                            for case let cwd? in pane.tabs.map(\.cwd) where cwd.hasPrefix("/") && !folders.contains(cwd) {
                                folders.append(cwd)
                            }
                        }
                    }
                }
                return folders
            },
            agentTabHost: agentTabHost,
            newChatPicks: newChatPicks,
            computerName: { if let nameOverride { return nameOverride } else { return await computerName() } },
            acpmuxEnvironment: acpmuxEnvironment,
            browserHosts: browserHosts,
            surfaceHosts: surfaceHosts,
            pairingSeed: IPhonePairingSeed.fromEnvironment(processEnvironment),
            chief: chief
        )
    }

    /// The account hostd registers under: the selected team, else the personal space; nil while signed out.
    public static func account(of auth: CloudAuth, signedIn: Bool) -> Account? {
        guard signedIn, let user = auth.user else { return nil }
        let team = auth.teamID
        return Account(
            userID: user.id, teamID: MobileHostLaunch.teamID(selected: team, userID: user.id),
            teamName: team.flatMap { id in auth.teams.first { $0.id == id }?.displayName },
            email: user.primaryEmail)
    }
}
