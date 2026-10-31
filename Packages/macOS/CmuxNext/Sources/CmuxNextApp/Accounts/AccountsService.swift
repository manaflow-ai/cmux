import AppKit
public import CmuxNextAccounts
import CmuxNextCloud
import CmuxNextCodeRouter
import CmuxNextDaemon
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
    unowned let services: AppServices
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
    private var activation: MainActorObservation?
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.accounts")

    static let fixtureHomeKey = "CMUX_NEXT_ACCOUNTS_HOME"

    init(services: AppServices) {
        self.services = services
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        showcaseMock = services.environment.showcase ? MockAccountsServices() : nil
        #else
        showcaseMock = nil
        #endif
        #if DEBUG
        if services.environment.authCaptureFixture {
            fixtureHome = URL(fileURLWithPath: "/cmux-auth-capture/providers", isDirectory: true)
        } else {
            fixtureHome = environment[Self.fixtureHomeKey].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        }
        #else
        fixtureHome = environment[Self.fixtureHomeKey].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        #endif
        let bundleID = services.environment.launch.bundleID
        let storeID = fixtureHome == nil ? bundleID : "\(bundleID ?? "cmux").fixture"
        #if DEBUG
        if services.environment.authCaptureFixture {
            keys = CaptureFixtureProviderKeyStore()
        } else {
            keys = KeychainProviderKeyStore(service: KeychainProviderKeyStore.service(bundleID: storeID))
        }
        #else
        keys = KeychainProviderKeyStore(service: KeychainProviderKeyStore.service(bundleID: storeID))
        #endif
        if services.environment.authCaptureFixture {
            labels = AccountLabelerStore(provider: CaptureFixtureLabelSalt())
        } else {
            labels = AccountLabelerStore(provider: KeychainAccountLabelSalt(service: KeychainAccountLabelSalt.service(bundleID: storeID)))
        }
        activation = MainActorObservation(NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.model.appDidBecomeActive()
        }
    }

    /// The detection inputs. The login env is captured once per launch
    /// (keys exported in shell rc files count); only presence is used.
    func detectionEnvironment() async -> DetectionEnvironment {
        let captureFixture = services.environment.authCaptureFixture
        let keys = keys
        let saved: Set<AIProvider> = captureFixture ? [] : await Task.detached { keys.savedProviders() }.value
        let labeler = await labeler()
        if let fixtureHome {
            return DetectionEnvironment(home: fixtureHome,
                                        environment: captureFixture ? [:] : ProcessInfo.processInfo.environment,
                                        files: captureFixture ? CaptureFixtureFiles() : LiveFileReader(), keychain: NoKeychain(),
                                        servers: captureFixture ? NoLocalServerProbe() : HTTPServerProbe(),
                                        labeler: labeler, savedKeys: saved)
        }
        if loginEnvironment == nil { loginEnvironment = await LoginEnvironment.shared.capture() ?? ProcessInfo.processInfo.environment }
        return DetectionEnvironment(home: FileManager.default.homeDirectoryForCurrentUser, environment: loginEnvironment ?? [:],
                                    files: LiveFileReader(), keychain: SystemKeychainProbe(), servers: HTTPServerProbe(),
                                    labeler: labeler, savedKeys: saved)
    }

    /// The account labeler; the first call reads or creates the Keychain salt.
    func labeler() async -> AccountLabeler {
        #if DEBUG
        if services.environment.authCaptureFixture {
            return AccountLabeler(salt: Data("cmux-auth-capture-label-salt".utf8))
        }
        #endif
        let labeler = await labels.labeler()
        if handlesStable, let failure = await labels.saltFailure {
            handlesStable = false
            logger.error("account label salt unavailable (\(failure, privacy: .public)); handles last for this launch only")
        }
        return labeler
    }

    var client: CodeRouterClient? {
        let cloud = services.cloud
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

    var cmuxAccount: CmuxAccountState { showcaseMock?.cmuxAccount ?? CmuxAccountState(services.cloud.auth) }

    func runCmuxAccount(_ action: CmuxAccountAction) {
        if let showcaseMock { showcaseMock.runCmuxAccount(action); model.refresh(); return }
        services.cloud.auth.run(action, signOut: { [services] in await services.cloud.signOut() }, refresh: { [weak self] in self?.model.refresh() })
    }

    var activeTeam: ActiveTeam? { showcaseMock != nil ? showcaseMock?.activeTeam : services.cloud.isSignedIn ? services.cloud.auth.activeTeam : nil }

    var teamBackend: (any AccountsTeamBackend)? { showcaseMock.map { $0 as any AccountsTeamBackend } ?? services.cloud.auth }

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
        let credential = try await Task.detached { try resolver.credential(for: provider, pasted: pasted) }.value
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

    func saveKey(_ key: String, for provider: AIProvider) throws {
        if let showcaseMock { try showcaseMock.saveKey(key, for: provider) } else { try keys.save(key, for: provider) }
    }

    func deleteSavedKey(for provider: AIProvider) throws {
        if let showcaseMock { try showcaseMock.deleteSavedKey(for: provider) } else { try keys.delete(for: provider) }
    }

    /// Types `line` and Return into a new terminal tab of the focused pane,
    /// so the provider's own login runs where the user can see and answer it.
    @discardableResult
    private func runInTerminal(_ line: String) -> Bool {
        let line = services.environment.authCaptureFixture ? "/usr/bin/printf 'Provider sign-in capture: local terminal opened\\n'" : line
        let opened = services.inFrontPane { $0.newTerminalTab(typing: line + "\r") }
        if !opened { logger.info("no local pane for a terminal tab") }
        return opened
    }

    /// Opens `url` in a new browser tab of the main window's local pane.
    @discardableResult
    private func openPage(_ url: URL) -> Bool {
        let url = services.environment.authCaptureFixture ? URL(fileURLWithPath: "/dev/null") : url
        let opened = services.inFrontPane { $0.newBrowserTab(url: url) }
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

/// Capture fixture: provider detection must not probe a developer's loopback
/// model servers. Its isolated provider home is still read through the real
/// detector and file reader.
private struct NoLocalServerProbe: LocalServerProbing {
    func isReachable(_ url: URL) async -> Bool { false }
}

#if DEBUG
private final class CaptureFixtureProviderKeyStore: ProviderKeyStoring, Sendable {
    private let values = Mutex<[AIProvider: String]>([:])

    func savedProviders() -> Set<AIProvider> { values.withLock { Set($0.keys) } }
    func save(_ key: String, for provider: AIProvider) throws { values.withLock { $0[provider] = key } }
    func key(for provider: AIProvider) throws -> String? { values.withLock { $0[provider] } }
    func delete(for provider: AIProvider) throws { _ = values.withLock { $0.removeValue(forKey: provider) } }
}

#endif

/// A virtual provider home: even an existing file at this path is never read.
private struct CaptureFixtureFiles: FileReading {
    func data(at url: URL) -> Data? { nil }
    func exists(_ url: URL) -> Bool { false }
}

private struct CaptureFixtureLabelSalt: AccountLabelSaltProviding {
    func salt() throws -> Data { Data("cmux-auth-capture-label-salt".utf8) }
}
