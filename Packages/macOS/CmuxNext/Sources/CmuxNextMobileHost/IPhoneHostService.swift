public import AppKit
import CmuxNextAgentPane
import CmuxNextCompat
public import CmuxNextMobile
public import Foundation
public import Observation
import CmuxNextWakeups
import os

/// Settings > Mobile: runs the bundled `cmux-mobile-host` (the cmux iPhone host,
/// cmux-next-ios/PROTOCOL.md) while `mobile.allowIPhoneConnections` (cmux.json) is on
/// and an account is signed in, so the phone app reaches this Mac's own
/// daemon and acpmux with no separate host to start. ``MobileHostSupervisor``
/// owns the process; this model follows the toggle and the account and
/// projects the state for the Settings page.
@MainActor @Observable
public final class IPhoneHostService {
    /// The signed-in account hostd registers under.
    public struct Account: Equatable, Sendable {
        /// The Stack user id (JWT `sub`).
        public var userID: String
        /// The Stack team, or `personal-<userId>`.
        public var teamID: String
        /// The team's name; nil for the personal space.
        public var teamName: String?
        /// The account's email, shown as "Registered as <email>" (phones sign in with the same one).
        public var email: String?

        public init(userID: String, teamID: String, teamName: String?, email: String?) {
            self.userID = userID
            self.teamID = teamID
            self.teamName = teamName
            self.email = email
        }
    }

    /// What the service needs from the app; ``wire(auth:daemon:acpmuxHost:settings:bundleID:computerName:processEnvironment:)`` sets it.
    struct Dependencies {
        /// The bundled hostd (`Contents/Resources/bin/cmux-mobile-host`), nil when this build has none.
        var executable: URL?
        /// The mobile service.
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
        /// The folders of the tabs this Mac's daemon lists now (absolute, deduplicated):
        /// a phone may start agent chats there (``MobileHostApproverSync/updateWorkspaceRoots(_:)``).
        var workspaceFolders: @MainActor @Sendable () -> [String] = { [] }
        /// This Mac's agent tab host (`install:<id>`), for agent tabs a phone creates.
        var agentTabHost: @MainActor () -> String? = { nil }
        /// The agent and model this Mac's New Tab page picked last (``NewChatPicks``):
        /// a phone's New Agent Chat starts there (``MobileHostApproverSync/updateNewChatPicks(_:)``).
        var newChatPicks: @MainActor @Sendable () -> NewChatPicks = { NewChatPicks() }
        var computerName: @Sendable () async -> String
        /// The app's acpmux, for the phones' approval keys; nil without agents.
        var acpmuxEnvironment: AcpmuxEnvironment?
        /// The app's browser hosts for the phone's streamed browser tabs; nil when this build has none.
        var browserHosts: (any MobileHostBrowserHosting)?
        /// The app's simulator surface sources for the phone's streamed phone tabs; nil when it cannot stream simulators.
        var surfaceHosts: (any MobileHostSurfaceHosting)?
        /// Test-only (DEBUG): phones this tagged test instance trusts without the prompt.
        var pairingSeed: IPhonePairingSeed?
        /// This app's own Chief owner: its session (from the app's `ChiefHome`, always known)
        /// and its socket once connected. hostd's `chief` service dials it; without it hostd
        /// guesses `~/.cmux/chief/default`, which is not a DEV or tagged build's Chief.
        var chief: (@MainActor () async -> ChiefPlacement?)?
    }

    /// Where this app's Chief owner listens (``Dependencies/chief``).
    public struct ChiefPlacement: Equatable, Sendable {
        /// `ChiefHome.session` of the app's Chief home.
        public var session: String
        /// The owner's socket, once the app is connected to it.
        public var socket: String?

        public init(session: String, socket: String?) {
            self.session = session
            self.socket = socket
        }
    }

    /// hostd's launch for `account`: the app's daemon, chat roots, agent tab host and its own Chief.
    static func launch(_ dependencies: Dependencies, executable: URL, account: Account, deviceID: String,
                       deviceName: String, daemonSocket: String, chief: ChiefPlacement?) -> MobileHostLaunch {
        var launch = MobileHostLaunch(
            executable: executable, baseURL: dependencies.baseURL, teamID: account.teamID, userID: account.userID,
            deviceID: deviceID, deviceName: deviceName, daemonSocket: daemonSocket,
            stateDirectory: dependencies.stateDirectory, fileRoots: dependencies.fileRoots(),
            stackProjectID: dependencies.stackProjectID, agentTabHost: dependencies.agentTabHost())
        launch.browserHosts = dependencies.browserHosts != nil
        launch.surfaceHosts = dependencies.surfaceHosts != nil
        launch.chiefSession = chief?.session
        launch.chiefSocket = chief?.socket
        return launch
    }

    /// `mobile.allowIPhoneConnections`, as the settings file has it.
    private(set) var allowed = false
    private(set) var account: Account?
    private(set) var state = MobileHostState()
    /// The account's phones on the mobile service (Settings > Mobile's list with Remove).
    private(set) var knownPhones: [MobileHostKnownPhone] = []
    /// Which phones may hold an acpmux credential is known: ``knownPhones`` is the signed-in
    /// account's list, read since it signed in, or iPhone connections are off (none may).
    @ObservationIgnored private(set) var phonesKnown = false
    /// The setting has been read once (``allowed`` false before that is not "off").
    @ObservationIgnored private var allowedRead = false
    /// Why the last list read or removal failed, shown under the list; nil when it worked.
    private(set) var phonesError: String?
    /// The signed-in user's pairing (cmux-next-ios verify/phone-approvals.md): every pairing decision
    /// is its own; this service shows the prompt and saves and pushes the list as each step says.
    internal(set) var pairing = MobileHostPairing()
    /// The read of ``paired`` in flight, and the phones forgotten while it runs (``loadPaired(signedOut:)``).
    @ObservationIgnored var pairedLoad = MobileHostPairedLoad()
    /// The owner removed this Mac from the account's devices (from a phone or the API).
    /// hostd stays stopped until the person allows iPhone connections again: Allow Again,
    /// the setting off and on, or signing in again. Then it registers as a new device.
    public private(set) var removed = false
    @ObservationIgnored private var signedOutSinceRemoval = false
    @ObservationIgnored var dependencies: Dependencies?
    @ObservationIgnored private var listing: Task<Void, Never>?
    @ObservationIgnored let supervisor = MobileHostSupervisor()
    /// The pre-approval behind this Mac's pairing code (``pairInvite()``): a phone presenting the
    /// live one pairs without the prompt, once.
    @ObservationIgnored var pairTokens = MobileHostPairTokens()
    /// This Mac's identity public key, as hostd proves it to phones (nil until hostd started).
    @ObservationIgnored private(set) var macPublicKey: Data?
    /// The open "Allow … to connect?" dialog: its dialog id and the request it shows.
    @ObservationIgnored var pairDialog: (id: Int, request: MobileHostPairRequest)?
    /// The banner and Dock bounce that tell the person about a request while cmux is not in front.
    @ObservationIgnored public var pairNotices: IPhonePairNotices?
    /// The Dock bounce of the waiting requests, cancelled once they are answered.
    @ObservationIgnored var attentionRequest: Int?
    /// The frontmost cmux main window, which the pairing prompt attaches to as a sheet.
    @ObservationIgnored public var pairWindow: (@MainActor () -> NSWindow?)?
    /// Observers that show a waiting prompt once a cmux window is on screen.
    @ObservationIgnored var pairWindowWatch: [EventSubscription] = []
    @ObservationIgnored var approverSync: MobileHostApproverSync?
    @ObservationIgnored var followingFolders: ServiceObservation<[String]>?
    @ObservationIgnored var followingPicks: ServiceObservation<NewChatPicks?>?
    @ObservationIgnored var pairingWatch: Task<Void, Never>?
    /// The one reconcile in flight; each waits for the previous one.
    @ObservationIgnored private var applying: Task<Void, Never>?
    @ObservationIgnored var watching: Task<Void, Never>?
    @ObservationIgnored var following: ServiceObservation<Bool>?
    @ObservationIgnored var followingAccount: ServiceObservation<Account?>?
    /// Bumped by each phone list read; an older read's answer is dropped.
    @ObservationIgnored private var listGeneration: UInt64 = 0
    /// The app's deadline placer and main-thread scheduler (``wire(auth:daemon:acpmuxHost:acpmuxEnvironment:agentTabHost:newChatPicks:chief:surfaceHosts:settings:deadlines:appEvents:bundleID:computerName:processEnvironment:)``).
    @ObservationIgnored var deadlines: MainDeadlineScheduler?
    /// The app's one fan-out of app-wide notices: the pairing prompt waits on it for a window.
    @ObservationIgnored var appEvents: AppEvents?
    /// The user and team hostd runs for now (the toggle on); a name or email change does not restart it.
    @ObservationIgnored private var running: String?
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.iphone")

    /// A host that runs nothing until it is wired and an account with the setting on arrives.
    public init() {}

    /// hostd reported a state (``followSupervisor(on:)``).
    func stateArrived(_ next: MobileHostState) {
        let before = state
        state = next
        if next.phase == .removed, before.phase != .removed { recordRemoval() }
        // The list follows what hostd reports: online, and each phone that comes or goes.
        if next.phase == .online, before.phase != .online || before.phones.map(\.sessionID) != next.phones.map(\.sessionID) {
            refreshPhones()
        }
    }

    /// Reads the account's phones from the mobile service (latest read wins). The token and the read run off
    /// main; the list applies in one visible task.
    public func refreshPhones() {
        listing?.cancel()
        listGeneration &+= 1
        guard allowed, account != nil, let dependencies, let mainWork = deadlines?.work else {
            knownPhones = []
            // Connections turned off: no phone holds a credential and their records end. Before the
            // setting or the account is read, which phones may is not known yet.
            phonesKnown = allowedRead && !allowed && account != nil
            phonesError = nil
            return pushListedPhones()
        }
        let directory = MobileHostDeviceDirectory(baseURL: dependencies.baseURL), accessToken = dependencies.accessToken
        let generation = listGeneration
        // task-owner: stored in `listing`; a newer read cancels it
        listing = Task { @concurrent [weak self] in
            let read: Result<[MobileHostKnownPhone], any Error>
            do { read = .success(try await directory.phones(token: accessToken(false))) } catch { read = .failure(error) }
            guard !Task.isCancelled else { return }
            mainWork.postFromAnyThread(.visible, owner: "IPhoneHost.phones") { [weak self] in self?.phonesRead(read, generation: generation) }
        }
    }

    private func phonesRead(_ read: Result<[MobileHostKnownPhone], any Error>, generation: UInt64) {
        guard generation == listGeneration else { return }
        switch read {
        case .success(let phones):
            knownPhones = phones
            phonesKnown = true
            phonesError = nil
            pushListedPhones()
        case .failure:
            phonesError = IPhoneHostStrings.listFailed
        }
    }

    /// Removes `id`'s phone on the mobile service (all its device ids), ends its live links in
    /// hostd, and re-reads the list. A phone still signed in to the account registers again
    /// when it next connects.
    public func removePhone(id: String) async {
        guard let dependencies, let phone = knownPhones.first(where: { $0.id == id || $0.owns(id) }) else { return }
        do {
            try await MobileHostDeviceDirectory(baseURL: dependencies.baseURL).remove(phone, token: dependencies.accessToken(false))
            await supervisor.drop(phoneDeviceIDs: phone.deviceIDs)
            // Its pairing goes too: its links and Face ID approvals stop at once.
            for deviceID in phone.deviceIDs { revokePhone(id: deviceID) }
            knownPhones.removeAll { $0.id == phone.id }
            phonesError = nil
            pushListedPhones()
        } catch {
            logger.error("iPhone removal failed: \(String(describing: error), privacy: .public)")
            phonesError = IPhoneHostStrings.removeFailed
        }
        refreshPhones()
    }

    /// The account changed (sign-in, sign-out, team switch).
    public func accountChanged(_ account: Account?) {
        guard account != self.account else { return }
        let signedOut = account == nil && self.account != nil
        // Signing out after a removal and signing in again allows connections again. (A
        // relaunch restores the session without a sign-out, so the removal holds.)
        if removed, account == nil { signedOutSinceRemoval = true }
        if account != nil, signedOutSinceRemoval {
            signedOutSinceRemoval = false
            clearRemoval()
        }
        self.account = account
        phonesKnown = false
        loadPaired(signedOut: signedOut)
        reconcile()
        refreshPhones()
    }

    /// hostd reported the removal: remember it (across relaunches) and forget the device id.
    private func recordRemoval() {
        removed = true
        pairTokens.revoke()
        guard let dependencies, let key = running else { return }
        do {
            try MobileHostRemovalMarker(directory: dependencies.stateDirectory)
                .record(account: key, identity: MobileHostDeviceIdentity(directory: dependencies.stateDirectory))
        } catch {
            logger.error("could not record the removal: \(String(describing: error), privacy: .public)")
        }
    }

    /// The person allowed iPhone connections again after a removal (Settings > Mobile >
    /// Allow Again): hostd registers this Mac as a new device.
    public func allowAgain() {
        clearRemoval()
        running = nil
        reconcile()
    }

    private func clearRemoval() {
        if let dependencies { MobileHostRemovalMarker(directory: dependencies.stateDirectory).clear() }
        removed = false
    }

    func setAllowed(_ allowed: Bool) {
        let first = !allowedRead
        allowedRead = true
        guard allowed != self.allowed else {
            // Read off at launch: the phones' records end too (``refreshPhones()``).
            if first { refreshPhones() }
            return
        }
        // Turning the setting on again is the person allowing connections again.
        if allowed, removed { clearRemoval() }
        // A pairing code shown before the switch went off pairs nothing afterwards.
        if !allowed { pairTokens.revoke() }
        self.allowed = allowed
        // Turning connections off withdraws the waiting pairing requests and their prompt.
        if !allowed { resetPrompts() }
        reconcile()
        refreshPhones()
    }

    /// App quit: hostd ends with the app (closing its stdin ends it too). Called only from
    /// `applicationWillTerminate`.
    public func stop() {
        running = nil
        following?.cancel()
        followingAccount?.cancel()
        applying?.cancel()
        pairingWatch?.cancel()
        followingFolders?.cancel()
        followingPicks?.cancel()
        approverSync?.stop()
        // The paired list's queued saves (a removal's new list among them) finish before the app
        // ends: a bounded wait during termination, the threading model's `terminate` allowance.
        allowBlocking(.terminate) { MobileHostPairedDevicesFile.flush() }
        quietAttention()
        let supervisor = supervisor
        // task-owner: teardown hop; the supervisor's stop is idempotent
        Task { @concurrent in await supervisor.stop() }
    }

    private func reconcile() {
        let want = allowed ? account : nil
        let key = want.map { "\($0.userID)\u{0}\($0.teamID)" }
        guard key != running else { return }
        running = key
        let previous = applying
        let dependencies = dependencies
        let supervisor = supervisor
        let allowed = allowed
        // task-owner: stored in `applying`; each reconcile awaits the one before it
        // main-hop-allow: the reconciles chain in order on the supervisor actor; this task only awaits it and the app's main-actor seams
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
            // Removed by the owner (this launch or an earlier one): stay stopped.
            if let key, MobileHostRemovalMarker(directory: dependencies.stateDirectory).account() == key {
                self?.removed = true
                self?.pairTokens.revoke()
                await supervisor.stop(phase: .removed)
                return
            }
            do {
                let socket = try await dependencies.daemonSocket()
                let deviceID = try MobileHostDeviceIdentity(directory: dependencies.stateDirectory).deviceID()
                // The key phones pin for this Mac (Keychain; created on first use), read off the
                // main actor: a Keychain call must never hold launch (a re-signed rig app's access
                // prompt did, and the watchdog killed it).
                let store = MobileHostMacIdentityStore(bundleID: dependencies.stateDirectory.deletingLastPathComponent().lastPathComponent,
                                                stateDirectory: dependencies.stateDirectory)
                // task-owner: one Keychain read per hostd start; awaited here
                let identity = try await Task.detached { try store.loadOrCreate() }.value
                let name = await dependencies.computerName()
                let chief = await dependencies.chief?()
                guard !Task.isCancelled, self?.running == key else { return }
                self?.macPublicKey = identity.publicKey
                let launch = Self.launch(dependencies, executable: executable, account: want, deviceID: deviceID,
                                         deviceName: name, daemonSocket: socket, chief: chief)
                await supervisor.start(.init(
                    launch: launch, accessToken: dependencies.accessToken, acpmux: dependencies.acpmux,
                    log: dependencies.stateDirectory.appendingPathComponent("cmux-mobile-host.log", isDirectory: false),
                    browserHosts: dependencies.browserHosts, macIdentity: identity,
                    surfaceHosts: dependencies.surfaceHosts))
            } catch {
                logger.error("iPhone host not started: \(String(describing: error), privacy: .public)")
                await supervisor.stop(phase: .waiting(String(describing: error)))
                // A later account or toggle change tries again.
                if self?.running == key { self?.running = nil }
            }
        }
    }
}
