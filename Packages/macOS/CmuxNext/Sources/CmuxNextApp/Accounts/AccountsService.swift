import struct CmuxSafeConcurrency.OwnerReference
import AppKit
public import CmuxNextAccounts
import CmuxNextCloud
import CmuxNextCodeRouter
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import os
import CmuxNextCompat

/// Owns the Accounts screen's model and its `AccountsServices`: detection
/// over the login-shell environment, the cmux Keychain item for pasted
/// keys, and the CodeRouter control plane as the signed-in cmux user.
/// Settings > Accounts, the onboarding step, the palette and the CLI all
/// act through this one model (plans/cmux-next/coderouter.md).
@MainActor
final class AccountsService: AccountsServices {
    private let servicesReference: OwnerReference<AppServices>
    /// The app's services, which own this; nil (reported) only once they are gone.
    var services: AppServices? { servicesReference.resolve() }
    private(set) lazy var model = AccountsModel(services: self)
    let keys: any ProviderKeyStoring
    /// The per-user salt behind every `acct_…` handle (Keychain, read once off the main actor).
    let labels: AccountLabelerStore
    /// Test launches: detect in this fixture home, with the app's own
    /// environment and no Keychain probe, so no real sign-in is read.
    let fixtureHome: URL?
    /// The showcase profile uses the package's deterministic account fixture;
    /// it must never read or mutate a user's real credentials.
    private let showcaseMock: MockAccountsServices?
    private var loginEnvironment: [String: String]?
    /// False once the Keychain salt failed: `acct_…` handles then last for
    /// this launch only (`accounts.list` says `handles_stable: false`).
    private(set) var handlesStable = true
    /// The app's one become-active observer (``AppEvents``) re-detects sign-ins made in another app.
    private var activation: EventSubscription?
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.accounts")

    static let fixtureHomeKey = "CMUX_NEXT_ACCOUNTS_HOME"

    /// `keys`: where pasted keys are kept (tests pass a fake); nil is the Keychain item of this build.
    init(services: AppServices, keys: (any ProviderKeyStoring)? = nil) {
        servicesReference = OwnerReference(services: services)
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        showcaseMock = services.environment.showcase ? MockAccountsServices() : nil
        #else
        showcaseMock = nil
        #endif
        fixtureHome = environment[Self.fixtureHomeKey].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        let bundleID = services.environment.launch.bundleID
        let storeID = fixtureHome == nil ? bundleID : "\(bundleID ?? "cmux").fixture"
        self.keys = keys ?? KeychainProviderKeyStore(service: KeychainProviderKeyStore.service(bundleID: storeID))
        labels = AccountLabelerStore(provider: KeychainAccountLabelSalt(service: KeychainAccountLabelSalt.service(bundleID: storeID)))
        activation = services.appEvents.subscribe(NSApplication.didBecomeActiveNotification, owner: "AccountsService.activation") { [weak self] in
            self?.model.appDidBecomeActive()
        }
    }

    /// The detection inputs. The login env is captured once per launch
    /// (keys exported in shell rc files count); only presence is used.
    func detectionEnvironment() async -> DetectionEnvironment {
        let keys = keys
        let saved = (try? await services?.work.run(.userVisible, mayBlock: .system) { keys.savedProviders() }) ?? []
        let labeler = await labeler()
        if let fixtureHome {
            return DetectionEnvironment(home: fixtureHome, environment: ProcessInfo.processInfo.environment, files: LiveFileReader(),
                                        keychain: NoKeychain(), servers: HTTPServerProbe(), labeler: labeler, savedKeys: saved)
        }
        if loginEnvironment == nil { loginEnvironment = await LoginEnvironment.shared.capture() ?? ProcessInfo.processInfo.environment }
        return DetectionEnvironment(home: FileManager.default.homeDirectoryForCurrentUser, environment: loginEnvironment ?? [:],
                                    files: LiveFileReader(), keychain: SystemKeychainProbe(), servers: HTTPServerProbe(),
                                    labeler: labeler, savedKeys: saved)
    }

    /// The account labeler; the first call reads or creates the Keychain salt.
    func labeler() async -> AccountLabeler {
        let labeler = await labels.labeler()
        if handlesStable, let failure = await labels.saltFailure {
            handlesStable = false
            logger.error("account label salt unavailable (\(failure, privacy: .public)); handles last for this launch only")
        }
        return labeler
    }

    var client: CodeRouterClient? {
        guard let cloud = services?.cloud else { return nil }
        let auth = cloud.auth, labels = labels
        return CodeRouterClient(baseURL: cloud.configuration.apiBaseURL, account: auth,
                                labeler: { await labels.labeler() })
    }

    // MARK: AccountsServices

    func detect() async -> [ProviderDetection] {
        // The showcase shows its fixture, never this Mac's own sign-ins.
        if let showcaseMock { return await showcaseMock.detect() }
        let environment = await detectionEnvironment()
        return await Task.detached { await ProviderDetector(environment: environment).detectAll() }.value
    }

    var cmuxAccount: CmuxAccountState {
        if let showcaseMock { return showcaseMock.cmuxAccount }
        guard let services else { return .signedOut }
        return CmuxAccountState(services.cloud.auth)
    }

    func runCmuxAccount(_ action: CmuxAccountAction) {
        if let showcaseMock { showcaseMock.runCmuxAccount(action); model.refresh(); return }
        guard let services else { return }
        services.cloud.auth.run(action, signOut: { [weak services] in await services?.cloud.signOut() }, refresh: { [weak self] in self?.model.refresh() })
    }

    var activeTeam: ActiveTeam? {
        if let showcaseMock { return showcaseMock.activeTeam }
        guard let cloud = services?.cloud, cloud.isSignedIn else { return nil }
        return cloud.auth.activeTeam
    }

    func linkedAccounts() async throws -> [LinkedAccount] {
        if let showcaseMock { return try await showcaseMock.linkedAccounts() }
        guard let client else { throw CodeRouterError.notSignedIn }
        return try await client.linkedAccounts()
    }

    func connect(_ provider: AIProvider, pasted: String?) async throws {
        if let showcaseMock { try await showcaseMock.connect(provider, pasted: pasted); return }
        guard let client else { throw CodeRouterError.notSignedIn }
        let resolver = CredentialResolver(environment: await detectionEnvironment(), keys: keys)
        // File and Keychain reads stay off the main actor.
        guard let services else { throw CancellationError() }
        let credential = try await services.work.run(.userBlocking, mayBlock: .system) { try resolver.credential(for: provider, pasted: pasted) }
        try await client.add(credential)
        logger.info("connected \(provider.rawValue, privacy: .public) to CodeRouter")
    }

    func remove(_ account: LinkedAccount) async throws {
        if let showcaseMock { try await showcaseMock.remove(account); return }
        guard let client else { throw CodeRouterError.notSignedIn }
        try await client.remove(account)
        logger.info("removed a \(account.provider.rawValue, privacy: .public) account from CodeRouter")
    }

    @discardableResult
    func reauthenticate(_ provider: AIProvider, plan: ReauthPlan) -> Bool {
        if let showcaseMock { return showcaseMock.reauthenticate(provider, plan: plan) }
        var opened = false
        plan.run(line: { opened = runInTerminal($0) }, page: { opened = openPage($0) })
        return opened
    }

    func runClaudeSetupToken() { if let showcaseMock { showcaseMock.runClaudeSetupToken() } else { runInTerminal("claude setup-token") } }

    func openConsole(_ url: URL) {
        if let showcaseMock { showcaseMock.openConsole(url); return }
        openPage(url)
    }

    /// The Keychain write runs on the system lane (it waits for securityd), never on main; `done` gets its
    /// error on main through the scheduler.
    func saveKey(_ key: String, for provider: AIProvider, done: @escaping @MainActor @Sendable ((any Error)?) -> Void) {
        if let showcaseMock { return showcaseMock.saveKey(key, for: provider, done: done) }
        guard let services else { return done(CancellationError()) }
        let keys = keys
        services.work.run(.userBlocking, mayBlock: .system) { Self.failure { try keys.save(key, for: provider) } }
            .reply(on: services.mainWork, class: .visible, owner: "accounts.saveKey") { done($0) }
    }

    func deleteSavedKey(for provider: AIProvider, done: @escaping @MainActor @Sendable ((any Error)?) -> Void) {
        if let showcaseMock { return showcaseMock.deleteSavedKey(for: provider, done: done) }
        guard let services else { return done(CancellationError()) }
        let keys = keys
        services.work.run(.userBlocking, mayBlock: .system) { Self.failure { try keys.delete(for: provider) } }
            .reply(on: services.mainWork, class: .visible, owner: "accounts.deleteSavedKey") { done($0) }
    }

    /// A Keychain call's error, nil when it succeeded.
    private nonisolated static func failure(_ body: () throws -> Void) -> (any Error)? {
        do {
            try body()
            return nil
        } catch {
            return error
        }
    }

    /// Types `line` and Return into a new terminal tab of the focused pane,
    /// so the provider's own login runs where the user can see and answer it.
    @discardableResult
    private func runInTerminal(_ line: String) -> Bool {
        let opened = services?.inFrontPane { $0.newTerminalTab(typing: line + "\r") } ?? false
        if !opened { logger.info("no local pane for a terminal tab") }
        return opened
    }

    /// Opens `url` in a new browser tab of the main window's local pane.
    @discardableResult
    private func openPage(_ url: URL) -> Bool {
        let opened = services?.inFrontPane { $0.newBrowserTab(url: url) } ?? false
        if !opened { logger.info("no local pane for a browser tab") }
        return opened
    }
}

/// Settings > Accounts drives the same Cloud sign-in as every other entry point.
extension CloudAuth: CmuxAccountSource {}

/// Fixture mode: no Keychain item exists.
private struct NoKeychain: KeychainProbing {
    func hasGenericPassword(service: String) -> Bool { false }
}
