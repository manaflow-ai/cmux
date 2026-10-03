import AppKit
import CmuxNextAccounts
import CmuxNextCodeRouter
import CmuxNextDaemon
import Foundation
import os

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
    private var loginEnvironment: [String: String]?
    /// False once the Keychain salt failed: `acct_…` handles then last for
    /// this launch only (`accounts.list` says `handles_stable: false`).
    private(set) var handlesStable = true
    private var activation: (any NSObjectProtocol)?
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.accounts")

    static let fixtureHomeKey = "CMUX_NEXT_ACCOUNTS_HOME"

    init(services: AppServices) {
        self.services = services
        let environment = ProcessInfo.processInfo.environment
        fixtureHome = environment[Self.fixtureHomeKey].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        let bundleID = services.environment.launch.bundleID
        let storeID = fixtureHome == nil ? bundleID : "\(bundleID ?? "cmux").fixture"
        keys = KeychainProviderKeyStore(service: KeychainProviderKeyStore.service(bundleID: storeID))
        labels = AccountLabelerStore(provider: KeychainAccountLabelSalt(service: KeychainAccountLabelSalt.service(bundleID: storeID)))
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.appDidBecomeActive() }
        }
    }

    /// The detection inputs. The login env is captured once per launch
    /// (keys exported in shell rc files count); only presence is used.
    func detectionEnvironment() async -> DetectionEnvironment {
        let keys = keys
        let saved = await Task.detached { keys.savedProviders() }.value
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
        guard let cloud = services.cloud else { return nil }
        let auth = cloud.auth, labels = labels
        return CodeRouterClient(baseURL: cloud.configuration.apiBaseURL, tokens: { try await auth.tokens() },
                                teamID: { await auth.teamID }, labeler: { await labels.labeler() })
    }

    // MARK: AccountsServices

    func detect() async -> [ProviderDetection] {
        let environment = await detectionEnvironment()
        return await Task.detached { await ProviderDetector(environment: environment).detectAll() }.value
    }

    var isSignedInToCmux: Bool { services.cloud?.isSignedIn ?? false }

    func signInToCmux() {
        guard let cloud = services.cloud else { return }
        // task-owner: one hosted sign-in; ends when the browser flow returns
        Task { [weak self] in
            _ = await cloud.auth.signIn()
            self?.model.refresh()
        }
    }

    func linkedAccounts() async throws -> [LinkedAccount] {
        guard let client else { throw CodeRouterError.notSignedIn }
        return try await client.linkedAccounts()
    }

    func connect(_ provider: AIProvider, pasted: String?) async throws {
        guard let client else { throw CodeRouterError.notSignedIn }
        let resolver = CredentialResolver(environment: await detectionEnvironment(), keys: keys)
        // File and Keychain reads stay off the main actor.
        let credential = try await Task.detached { try resolver.credential(for: provider, pasted: pasted) }.value
        try await client.add(credential)
        logger.info("connected \(provider.rawValue, privacy: .public) to CodeRouter")
    }

    func remove(_ account: LinkedAccount) async throws {
        guard let client else { throw CodeRouterError.notSignedIn }
        try await client.remove(account)
        logger.info("removed a \(account.provider.rawValue, privacy: .public) account from CodeRouter")
    }

    func reauthenticate(_ provider: AIProvider, plan: ReauthPlan) {
        switch plan {
        case .command:
            guard let line = plan.shellLine else { return }
            runInTerminal(line)
        case .page(let url):
            openConsole(url)
        case .none:
            break
        }
    }

    func runClaudeSetupToken() { runInTerminal("claude setup-token") }

    func openConsole(_ url: URL) {
        guard let pane = services.windows.active?.focusedPane else { return logger.info("no window for a browser tab") }
        pane.newBrowserTab(url: url)
    }

    func saveKey(_ key: String, for provider: AIProvider) throws { try keys.save(key, for: provider) }

    func deleteSavedKey(for provider: AIProvider) throws { try keys.delete(for: provider) }

    /// Types `line` and Return into a new terminal tab of the focused pane,
    /// so the provider's own login runs where the user can see and answer it.
    private func runInTerminal(_ line: String) {
        guard let pane = services.windows.active?.focusedPane else { return logger.info("no window for a terminal tab") }
        pane.newTerminalTab(typing: line + "\r")
    }
}

/// Fixture mode: no Keychain item exists.
private struct NoKeychain: KeychainProbing {
    func hasGenericPassword(service: String) -> Bool { false }
}
