import CmuxNextCompat
import CmuxNextMobile
import Foundation
import Observation
import os

/// Settings > Mobile: runs the bundled `cnx-hostd` (the cmux cnx phone host,
/// cnx-ios/PROTOCOL.md) while `mobile.allowIPhoneConnections` (cmux.json) is on
/// and an account is signed in, so the phone app reaches this Mac's own
/// daemon and acpmux with no separate host to start. ``CnxHostSupervisor``
/// owns the process; this model follows the toggle and the account and
/// projects the state for the Settings page.
@MainActor @Observable
final class IPhoneHostService {
    /// The signed-in account hostd registers under.
    struct Account: Equatable, Sendable {
        var userID: String
        /// The Stack team, or `personal-<userId>`.
        var teamID: String
        /// The team's name; nil for the personal space.
        var teamName: String?
    }

    /// What the service needs from the app; set once by `AppServices`.
    struct Dependencies {
        /// The bundled hostd (`Contents/Resources/bin/cnx-hostd`), nil when this build has none.
        var executable: URL?
        /// The cnx service.
        var baseURL: URL
        var stackProjectID: String
        /// Per-bundle state (device id, hostd log).
        var stateDirectory: URL
        var accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
        /// The app's own cmux-tui daemon socket.
        var daemonSocket: @MainActor () async throws -> String
        /// The app's acpmux WebSocket, starting acpmux when needed.
        var acpmux: @Sendable () async -> (url: URL, token: String)?
        /// Folders the phone may preview files from (the chat roots).
        var fileRoots: @MainActor () -> [String]
        var computerName: @Sendable () async -> String
    }

    /// `mobile.allowIPhoneConnections`, as the settings file has it.
    private(set) var allowed = false
    private(set) var account: Account?
    private(set) var state = CnxHostState()
    @ObservationIgnored var dependencies: Dependencies?
    @ObservationIgnored private let supervisor = CnxHostSupervisor()
    /// The one reconcile in flight; each waits for the previous one.
    @ObservationIgnored private var applying: Task<Void, Never>?
    @ObservationIgnored private var watching: Task<Void, Never>?
    @ObservationIgnored private var following: Task<Void, Never>?
    /// What hostd runs for now (account and toggle), so a repeated update does not restart it.
    @ObservationIgnored private var running: Account?
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.iphone")

    init() {
        let states = supervisor.states
        // task-owner: lives as long as the app; follows the supervisor's state stream
        watching = Task { [weak self] in
            for await next in states {
                self?.state = next
            }
        }
    }

    /// The account changed (sign-in, sign-out, team switch).
    func accountChanged(_ account: Account?) {
        guard account != self.account else { return }
        self.account = account
        reconcile()
    }

    /// Follows the setting: every writer (the Settings page, `cmux settings`, an
    /// edit of cmux.json) reaches the host through the settings file.
    func follow(allowed read: @escaping @MainActor @Sendable () -> Bool) {
        following?.cancel()
        // task-owner: lives as long as the app; re-reads the setting on each settings change
        following = Task { [weak self] in
            for await value in ObservationStream(read) {
                self?.setAllowed(value)
            }
        }
    }

    private func setAllowed(_ allowed: Bool) {
        guard allowed != self.allowed else { return }
        self.allowed = allowed
        reconcile()
    }

    /// App quit: hostd ends with the app (closing its stdin ends it too).
    func stop() {
        running = nil
        following?.cancel()
        applying?.cancel()
        let supervisor = supervisor
        // task-owner: teardown hop; the supervisor's stop is idempotent
        Task { await supervisor.stop() }
    }

    private func reconcile() {
        let want = allowed ? account : nil
        guard want != running else { return }
        running = want
        let previous = applying
        let dependencies = dependencies
        let supervisor = supervisor
        let allowed = allowed
        // task-owner: stored in `applying`; each reconcile awaits the one before it
        applying = Task { [weak self, logger] in
            await previous?.value
            guard let want, let dependencies else {
                await supervisor.stop(phase: .off)
                if allowed, self?.account == nil { await supervisor.show(.unavailable(IPhoneHostStrings.signedOut)) }
                return
            }
            guard let executable = dependencies.executable else {
                await supervisor.stop(phase: .unavailable(IPhoneHostStrings.unavailable))
                return
            }
            do {
                let socket = try await dependencies.daemonSocket()
                let deviceID = try CnxDeviceIdentity(directory: dependencies.stateDirectory).deviceID()
                let name = await dependencies.computerName()
                guard !Task.isCancelled, self?.running == want else { return }
                let launch = CnxHostLaunch(
                    executable: executable, baseURL: dependencies.baseURL, teamID: want.teamID, userID: want.userID,
                    deviceID: deviceID, deviceName: name, daemonSocket: socket,
                    stateDirectory: dependencies.stateDirectory, fileRoots: dependencies.fileRoots(),
                    stackProjectID: dependencies.stackProjectID)
                await supervisor.start(.init(
                    launch: launch, accessToken: dependencies.accessToken, acpmux: dependencies.acpmux,
                    log: dependencies.stateDirectory.appendingPathComponent("cnx-hostd.log", isDirectory: false)))
            } catch {
                logger.error("iPhone host not started: \(String(describing: error), privacy: .public)")
                await supervisor.stop(phase: .waiting(String(describing: error)))
                // A later account or toggle change tries again.
                if self?.running == want { self?.running = nil }
            }
        }
    }
}
