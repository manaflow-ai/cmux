import AppKit
import AuthenticationServices
import CMUXAuthCore
import Foundation
import StackAuth
#if canImport(Security)
import Security
#endif

private final class AuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthPresentationContext()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // ASWebAuthenticationSession invokes this on whichever thread called
        // session.start(). When beginSignIn() fires from the socket command
        // dispatch thread (cmux auth login), this callback lands off-main,
        // and any NSApp access must hop to main before returning.
        if Thread.isMainThread {
            return Self.currentAnchor()
        }
        var result: ASPresentationAnchor = NSWindow()
        DispatchQueue.main.sync {
            result = Self.currentAnchor()
        }
        return result
    }

    @MainActor
    private static func currentAnchor() -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? (NSApp.windows.first ?? NSWindow())
    }
}

enum AuthManagerError: LocalizedError {
    case invalidCallback
    case missingAccessToken

    var errorDescription: String? {
        switch self {
        case .invalidCallback:
            return String(
                localized: "settings.account.error.invalidCallback",
                defaultValue: "The sign-in callback was invalid."
            )
        case .missingAccessToken:
            return String(
                localized: "settings.account.error.missingAccessToken",
                defaultValue: "Account access token is unavailable."
            )
        }
    }
}

protocol StackAuthTokenStoreProtocol: TokenStoreProtocol, Sendable {
    func seed(accessToken: String, refreshToken: String) async
    func clear() async
    func currentAccessToken() async -> String?
    func currentRefreshToken() async -> String?
}

extension StackAuthTokenStoreProtocol {
    func seed(accessToken: String, refreshToken: String) async {
        await setTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    func clear() async {
        await clearTokens()
    }

    func currentAccessToken() async -> String? {
        await getStoredAccessToken()
    }

    func currentRefreshToken() async -> String? {
        await getStoredRefreshToken()
    }
}

protocol AuthClientProtocol: Sendable {
    func currentUser() async throws -> CMUXAuthUser?
    func listTeams() async throws -> [AuthTeamSummary]
    func currentAccessToken() async throws -> String?
    func signOut() async throws
}

extension AuthClientProtocol {
    func currentAccessToken() async throws -> String? { nil }
    func signOut() async throws {}
}

enum AuthKeychainServiceName {
    static let stableFallback = "com.cmuxterm.app.auth"

    static func make(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return stableFallback
        }
        return "\(bundleIdentifier).auth"
    }
}

@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager(tokenStore: AuthManager.defaultTokenStore())

    private static func defaultTokenStore() -> any StackAuthTokenStoreProtocol {
        #if DEBUG
        // Debug builds are ad-hoc signed and change their code signature on every
        // `reload.sh --tag` build. That breaks the Keychain ACL bound to the
        // previous signature, so macOS prompts for the login keychain password on
        // every token read. UserDefaults is fine here: tokens never leave the dev
        // machine, and release builds still use Keychain below.
        return UserDefaultsStackTokenStore()
        #else
        return KeychainStackTokenStore()
        #endif
    }

    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentUser: CMUXAuthUser?
    @Published private(set) var availableTeams: [AuthTeamSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRestoringSession = false
    @Published private(set) var didCompleteBrowserSignIn = false
    @Published var selectedTeamID: String? {
        didSet {
            guard selectedTeamID != oldValue else { return }
            settingsStore.selectedTeamID = selectedTeamID
        }
    }

    var resolvedTeamID: String? {
        Self.resolveTeamID(selectedTeamID: selectedTeamID, teams: availableTeams)
    }

    let requiresAuthenticationGate = false

    private let client: any AuthClientProtocol
    private let tokenStore: any StackAuthTokenStoreProtocol
    private let settingsStore: AuthSettingsStore
    private let urlOpener: (URL) -> Void

    init(
        client: (any AuthClientProtocol)? = nil,
        tokenStore: any StackAuthTokenStoreProtocol = KeychainStackTokenStore(),
        settingsStore: AuthSettingsStore = AuthSettingsStore(),
        urlOpener: ((URL) -> Void)? = nil
    ) {
        self.tokenStore = tokenStore
        self.settingsStore = settingsStore
        self.client = client ?? Self.makeDefaultClient(tokenStore: tokenStore)
        self.urlOpener = urlOpener ?? Self.defaultURLOpener
        self.currentUser = settingsStore.cachedUser()
        self.selectedTeamID = settingsStore.selectedTeamID
        self.isAuthenticated = self.currentUser != nil
        Task { [weak self] in
            await self?.restoreStoredSessionIfNeeded()
        }
    }

    private var loginPollTask: Task<Void, Never>?
    private var webAuthSession: ASWebAuthenticationSession?

    func beginSignIn() {
        loginPollTask?.cancel()
        webAuthSession?.cancel()
        webAuthSession = nil
        isLoading = true

        let signInURL = AuthEnvironment.signInURL()
        let callbackScheme = AuthEnvironment.callbackScheme

        let session = ASWebAuthenticationSession(
            url: signInURL,
            callbackURLScheme: callbackScheme
        ) { [weak self] callbackURL, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.isLoading = false
                    self.webAuthSession = nil
                }
                if let error {
                    NSLog("auth.webauth failed: %@", "\(error)")
                    return
                }
                guard let callbackURL else { return }
                do {
                    try await self.handleCallbackURL(callbackURL)
                } catch {
                    NSLog("auth.webauth callback failed: %@", "\(error)")
                }
            }
        }
        session.presentationContextProvider = AuthPresentationContext.shared
        session.prefersEphemeralWebBrowserSession = false

        if session.start() {
            webAuthSession = session
        } else {
            NSLog("auth.webauth: session.start() returned false")
            isLoading = false
        }
    }

    /// Shared CLI auth flow: initiate session, open browser, poll for token.
    /// Used by both the Settings sign-in button and `cmux login`.
    static func runCLIAuthFlow(
        urlOpener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) async throws -> String {
        let baseURL = AuthEnvironment.stackBaseURL.absoluteString
        let projectID = AuthEnvironment.stackProjectID
        let clientKey = AuthEnvironment.stackPublishableClientKey
        let handlerOrigin = AuthEnvironment.signInWebsiteOrigin.absoluteString

        // Step 1: Initiate CLI auth session
        let initBody = try JSONSerialization.data(withJSONObject: [
            "expires_in_millis": 7_200_000,
        ])
        let initJSON = try await stackAPIRequest(
            url: "\(baseURL)/api/v1/auth/cli",
            body: initBody,
            projectID: projectID,
            clientKey: clientKey
        )
        guard let pollingCode = initJSON["polling_code"] as? String,
              let loginCode = initJSON["login_code"] as? String else {
            throw AuthManagerError.invalidCallback
        }

        // Step 2: Open system browser to confirm page
        let confirmURL = URL(string: "\(handlerOrigin)/handler/cli-auth-confirm?login_code=\(loginCode)")!
        await MainActor.run { urlOpener(confirmURL) }

        // Step 3: Poll for token
        let pollBody = try JSONSerialization.data(withJSONObject: [
            "polling_code": pollingCode,
        ])
        let deadline = Date().addingTimeInterval(300) // 5 minutes
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 2_000_000_000)

            guard let pollJSON = try? await stackAPIRequest(
                url: "\(baseURL)/api/v1/auth/cli/poll",
                body: pollBody,
                projectID: projectID,
                clientKey: clientKey
            ),
            let status = pollJSON["status"] as? String else {
                continue
            }

            switch status {
            case "success":
                guard let token = pollJSON["refresh_token"] as? String else {
                    throw AuthManagerError.missingAccessToken
                }
                return token
            case "expired", "used":
                throw AuthManagerError.invalidCallback
            default:
                continue
            }
        }
        throw AuthManagerError.invalidCallback
    }

    private static func stackAPIRequest(
        url: String,
        body: Data,
        projectID: String,
        clientKey: String,
        extraHeaders: [String: String] = [:],
        method: String = "POST"
    ) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(projectID, forHTTPHeaderField: "x-stack-project-id")
        request.setValue(clientKey, forHTTPHeaderField: "x-stack-publishable-client-key")
        request.setValue("client", forHTTPHeaderField: "x-stack-access-type")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if method != "GET" && !body.isEmpty {
            request.httpBody = body
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthManagerError.invalidCallback
        }
        return json
    }

    func handleCallbackURL(_ url: URL) async throws {
        guard let payload = AuthCallbackRouter.callbackPayload(from: url) else {
            throw AuthManagerError.invalidCallback
        }

        isLoading = true
        defer { isLoading = false }

        await tokenStore.seed(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken
        )
        try await refreshSession()
        didCompleteBrowserSignIn = true
    }

    func seedTokensFromCLI(refreshToken: String, accessToken: String?) async {
        authLog("seedTokensFromCLI: refresh=\(refreshToken.prefix(10))... access=\(accessToken != nil ? "\(accessToken!.prefix(10))..." : "nil")")

        // If no access token provided, refresh it from Stack Auth first
        var resolvedAccess = accessToken
        if resolvedAccess == nil || resolvedAccess?.isEmpty == true {
            do {
                let json = try await Self.stackAPIRequest(
                    url: "\(AuthEnvironment.stackBaseURL.absoluteString)/api/v1/auth/sessions/current/refresh",
                    body: Data("{}".utf8),
                    projectID: AuthEnvironment.stackProjectID,
                    clientKey: AuthEnvironment.stackPublishableClientKey,
                    extraHeaders: ["x-stack-refresh-token": refreshToken]
                )
                resolvedAccess = json["access_token"] as? String
                authLog("seedTokensFromCLI: refreshed access token OK")
            } catch {
                authLog("seedTokensFromCLI: failed to refresh access token: \(error)")
            }
        }

        await tokenStore.setTokens(accessToken: resolvedAccess, refreshToken: refreshToken)
        do {
            try await refreshSession()
            authLog("seedTokensFromCLI: success user=\(currentUser?.primaryEmail ?? "nil")")
        } catch {
            authLog("seedTokensFromCLI: refreshSession failed: \(error)")
        }
    }

    struct SignInResult {
        let accessToken: String
        let refreshToken: String
        let email: String?
        let displayName: String?
        let userId: String
        let selectedTeamId: String?
        let teams: [AuthTeamSummary]
    }

    nonisolated static func signInWithCredentialDirectly(email: String, password: String) async throws -> SignInResult {
        authLog("signInDirectly: email=\(email)")
        let signInJSON = try await stackAPIRequest(
            url: "\(AuthEnvironment.stackBaseURL.absoluteString)/api/v1/auth/password/sign-in",
            body: try JSONSerialization.data(withJSONObject: ["email": email, "password": password]),
            projectID: AuthEnvironment.stackProjectID,
            clientKey: AuthEnvironment.stackPublishableClientKey
        )
        guard let accessToken = signInJSON["access_token"] as? String,
              let refreshToken = signInJSON["refresh_token"] as? String else {
            throw AuthManagerError.invalidCallback
        }
        let userJSON = try await stackAPIRequest(
            url: "\(AuthEnvironment.stackBaseURL.absoluteString)/api/v1/users/me",
            body: Data(), projectID: AuthEnvironment.stackProjectID,
            clientKey: AuthEnvironment.stackPublishableClientKey,
            extraHeaders: ["x-stack-access-token": accessToken], method: "GET"
        )
        let teamsJSON = try await stackAPIRequest(
            url: "\(AuthEnvironment.stackBaseURL.absoluteString)/api/v1/teams?user_id=me",
            body: Data(), projectID: AuthEnvironment.stackProjectID,
            clientKey: AuthEnvironment.stackPublishableClientKey,
            extraHeaders: ["x-stack-access-token": accessToken], method: "GET"
        )
        var teams: [AuthTeamSummary] = []
        if let items = teamsJSON["items"] as? [[String: Any]] {
            for item in items { if let id = item["id"] as? String {
                teams.append(AuthTeamSummary(id: id, displayName: item["display_name"] as? String ?? ""))
            }}
        }
        let selectedTeamFromAPI = userJSON["selected_team_id"] as? String
        authLog("signInDirectly: success user=\(userJSON["primary_email"] as? String ?? "nil") teams=\(teams.count) selectedTeam=\(selectedTeamFromAPI ?? "nil")")
        return SignInResult(accessToken: accessToken, refreshToken: refreshToken,
                           email: userJSON["primary_email"] as? String,
                           displayName: userJSON["display_name"] as? String,
                           userId: userJSON["id"] as? String ?? "",
                           selectedTeamId: selectedTeamFromAPI,
                           teams: teams)
    }

    func applySignInResult(_ result: SignInResult) {
        // Cache access token for fast synchronous reads
        lastKnownAccessToken = result.accessToken
        // Store tokens in keychain (fire-and-forget)
        let store = tokenStore
        Task.detached {
            await store.setTokens(accessToken: result.accessToken, refreshToken: result.refreshToken)
        }
        // Update published state synchronously on main actor
        let user = CMUXAuthUser(id: result.userId, primaryEmail: result.email, displayName: result.displayName)
        currentUser = user
        settingsStore.saveCachedUser(user)
        availableTeams = result.teams
        isAuthenticated = true
        selectedTeamID = Self.resolveTeamID(selectedTeamID: selectedTeamID, teams: result.teams)
        didCompleteBrowserSignIn = true
        authLog("applySignInResult: user=\(result.email ?? "nil") teams=\(result.teams.count) teamID=\(selectedTeamID ?? "nil")")
    }

    func signInWithCredential(email: String, password: String) async throws {
        authLog("signInWithCredential: email=\(email)")
        isLoading = true
        defer { isLoading = false }

        // Sign in directly via the Stack Auth API and store tokens ourselves,
        // bypassing the StackClientApp which has token refresh issues.
        let json = try await Self.stackAPIRequest(
            url: "\(AuthEnvironment.stackBaseURL.absoluteString)/api/v1/auth/password/sign-in",
            body: try JSONSerialization.data(withJSONObject: ["email": email, "password": password]),
            projectID: AuthEnvironment.stackProjectID,
            clientKey: AuthEnvironment.stackPublishableClientKey
        )
        guard let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String else {
            throw AuthManagerError.invalidCallback
        }
        await tokenStore.setTokens(accessToken: accessToken, refreshToken: refreshToken)

        // Fetch user info directly with the access token
        let userJSON = try await Self.stackAPIRequest(
            url: "\(AuthEnvironment.stackBaseURL.absoluteString)/api/v1/users/me",
            body: Data(),
            projectID: AuthEnvironment.stackProjectID,
            clientKey: AuthEnvironment.stackPublishableClientKey,
            extraHeaders: ["x-stack-access-token": accessToken],
            method: "GET"
        )
        let user = CMUXAuthUser(
            id: userJSON["id"] as? String ?? "",
            primaryEmail: userJSON["primary_email"] as? String,
            displayName: userJSON["display_name"] as? String
        )

        // Fetch teams
        let teamsJSON = try await Self.stackAPIRequest(
            url: "\(AuthEnvironment.stackBaseURL.absoluteString)/api/v1/teams?user_id=me",
            body: Data(),
            projectID: AuthEnvironment.stackProjectID,
            clientKey: AuthEnvironment.stackPublishableClientKey,
            extraHeaders: ["x-stack-access-token": accessToken],
            method: "GET"
        )
        var teams: [AuthTeamSummary] = []
        if let items = teamsJSON["items"] as? [[String: Any]] {
            for item in items {
                if let id = item["id"] as? String {
                    teams.append(AuthTeamSummary(
                        id: id,
                        displayName: item["display_name"] as? String ?? ""
                    ))
                }
            }
        }

        currentUser = user
        settingsStore.saveCachedUser(user)
        availableTeams = teams
        isAuthenticated = true
        selectedTeamID = Self.resolveTeamID(selectedTeamID: selectedTeamID, teams: teams)
        authLog("signInWithCredential: success user=\(user.primaryEmail ?? "nil") teams=\(teams.count) teamID=\(selectedTeamID ?? "nil")")
        didCompleteBrowserSignIn = true
    }

    func signOut() async {
        try? await client.signOut()
        await tokenStore.clear()
        clearSessionState(clearSelectedTeam: true)
    }

    /// Cached access token for fast synchronous reads (no actor hops).
    private var lastKnownAccessToken: String?

    func getAccessToken() async throws -> String {
        if let cached = lastKnownAccessToken, !cached.isEmpty {
            return cached
        }
        throw AuthManagerError.missingAccessToken
    }

    private func restoreStoredSessionIfNeeded() async {
        let accessToken = await tokenStore.currentAccessToken()
        let refreshToken = await tokenStore.currentRefreshToken()
        let hasAccessToken = accessToken != nil && !(accessToken?.isEmpty ?? true)
        let hasRefreshToken = refreshToken != nil && !(refreshToken?.isEmpty ?? true)
        authLog("restore: hasAccess=\(hasAccessToken) hasRefresh=\(hasRefreshToken)")
        let hasTokens = hasAccessToken || hasRefreshToken
        guard hasTokens else {
            clearSessionState(clearSelectedTeam: true)
            return
        }

        isAuthenticated = currentUser != nil
        isRestoringSession = true
        defer { isRestoringSession = false }

        do {
            try await refreshSession()
            authLog("restore: success user=\(currentUser?.primaryEmail ?? "nil") auth=\(isAuthenticated)")
        } catch {
            authLog("restore: failed error=\(error)")
            if currentUser == nil {
                isAuthenticated = false
            }
        }
    }

    nonisolated static func authLog(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] auth: \(message)\n"
        let path = "/tmp/cmux-auth-debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }

    private func authLog(_ message: String) {
        Self.authLog(message)
    }

    private func refreshSession() async throws {
        let user: CMUXAuthUser?
        do {
            user = try await client.currentUser()
        } catch {
            authLog("refreshSession: getUser failed: \(error)")
            throw error
        }
        let teams: [AuthTeamSummary]
        do {
            teams = try await client.listTeams()
        } catch {
            authLog("refreshSession: listTeams failed: \(error)")
            throw error
        }
        let hasRefreshToken = await tokenStore.currentRefreshToken() != nil
        authLog("refreshSession: user=\(user?.primaryEmail ?? "nil") teams=\(teams.count) hasRefresh=\(hasRefreshToken)")
        currentUser = user
        settingsStore.saveCachedUser(user)
        availableTeams = teams
        isAuthenticated = user != nil || hasRefreshToken
        selectedTeamID = Self.resolveTeamID(selectedTeamID: selectedTeamID, teams: teams)
    }

    private func clearSessionState(clearSelectedTeam: Bool) {
        availableTeams = []
        currentUser = nil
        isAuthenticated = false
        didCompleteBrowserSignIn = false
        if clearSelectedTeam {
            selectedTeamID = nil
        }
        settingsStore.saveCachedUser(nil)
    }

    private static func makeDefaultClient(
        tokenStore: any StackAuthTokenStoreProtocol
    ) -> any AuthClientProtocol {
        UITestAuthClient.makeIfEnabled(tokenStore: tokenStore) ?? LiveAuthClient(tokenStore: tokenStore)
    }

    private static func defaultURLOpener(_ url: URL) {
        let environment = ProcessInfo.processInfo.environment
        if let capturePath = environment["CMUX_UI_TEST_CAPTURE_OPEN_URL_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !capturePath.isEmpty {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: capturePath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? url.absoluteString.write(
                to: URL(fileURLWithPath: capturePath),
                atomically: true,
                encoding: .utf8
            )
            return
        }
        // Open in the user's actual default browser. urlsForApplications(toOpen:)
        // returns candidates in LaunchServices priority order (user's chosen
        // default first). Skip cmux itself, since Info.plist advertises http/https
        // at LSHandlerRank=Default and otherwise the app could re-open the URL in
        // its own embedded WebView.
        let ownBundleIDs: Set<String> = {
            var ids: Set<String> = []
            if let id = Bundle.main.bundleIdentifier { ids.insert(id) }
            return ids
        }()
        let candidates = NSWorkspace.shared.urlsForApplications(toOpen: url)
        let browserURL = candidates.first { appURL in
            guard let id = Bundle(url: appURL)?.bundleIdentifier else { return true }
            if ownBundleIDs.contains(id) { return false }
            let lower = id.lowercased()
            return !lower.hasPrefix("dev.cmux.") && !lower.hasPrefix("com.cmuxterm.")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = false
        if let browserURL {
            NSWorkspace.shared.open([url], withApplicationAt: browserURL, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private static func resolveTeamID(
        selectedTeamID: String?,
        teams: [AuthTeamSummary]
    ) -> String? {
        if let selectedTeamID,
           teams.contains(where: { $0.id == selectedTeamID }) {
            return selectedTeamID
        }
        return teams.first?.id
    }
}


private actor UserDefaultsStackTokenStore: StackAuthTokenStoreProtocol {
    private static let accessKey = "cmux.auth.debug.accessToken"
    private static let refreshKey = "cmux.auth.debug.refreshToken"
    private let defaults = UserDefaults.standard

    func getStoredAccessToken() async -> String? {
        defaults.string(forKey: Self.accessKey)
    }

    func getStoredRefreshToken() async -> String? {
        defaults.string(forKey: Self.refreshKey)
    }

    func setTokens(accessToken: String?, refreshToken: String?) async {
        if let accessToken, !accessToken.isEmpty {
            defaults.set(accessToken, forKey: Self.accessKey)
        } else {
            defaults.removeObject(forKey: Self.accessKey)
        }
        if let refreshToken, !refreshToken.isEmpty {
            defaults.set(refreshToken, forKey: Self.refreshKey)
        } else {
            defaults.removeObject(forKey: Self.refreshKey)
        }
    }

    func clearTokens() async {
        defaults.removeObject(forKey: Self.accessKey)
        defaults.removeObject(forKey: Self.refreshKey)
    }

    func compareAndSet(
        compareRefreshToken: String,
        newRefreshToken: String?,
        newAccessToken: String?
    ) async {
        guard defaults.string(forKey: Self.refreshKey) == compareRefreshToken else { return }
        if newRefreshToken == nil && newAccessToken == nil { return }
        await setTokens(accessToken: newAccessToken, refreshToken: newRefreshToken)
    }
}

private actor KeychainStackTokenStore: StackAuthTokenStoreProtocol {
    private static let accessTokenAccount = "cmux-auth-access-token"
    private static let refreshTokenAccount = "cmux-auth-refresh-token"
    // Each tagged build uses its own keychain service (per bundle ID) to avoid cross-build keychain prompts.
    private let service = AuthKeychainServiceName.make()

    // In-memory cache to avoid keychain prompts in environments where
    // the login keychain is locked (SSH, background processes).
    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?

    func getStoredAccessToken() async -> String? {
        cachedAccessToken ?? keychainValueSafe(account: Self.accessTokenAccount)
    }

    func getStoredRefreshToken() async -> String? {
        cachedRefreshToken ?? keychainValueSafe(account: Self.refreshTokenAccount)
    }

    func setTokens(accessToken: String?, refreshToken: String?) async {
        AuthManager.authLog("setTokens: access=\(accessToken != nil ? "\(accessToken!.prefix(10))..." : "nil") refresh=\(refreshToken != nil ? "\(refreshToken!.prefix(10))..." : "nil")")
        // Always update in-memory cache (instant, no prompt)
        cachedAccessToken = (accessToken?.isEmpty == false) ? accessToken : nil
        cachedRefreshToken = (refreshToken?.isEmpty == false) ? refreshToken : nil
        // Best-effort keychain persistence (may block if keychain is locked)
        if let accessToken, !accessToken.isEmpty {
            setKeychainValueSafe(accessToken, account: Self.accessTokenAccount)
        }
        if let refreshToken, !refreshToken.isEmpty {
            setKeychainValueSafe(refreshToken, account: Self.refreshTokenAccount)
        }
    }

    func clearTokens() async {
        AuthManager.authLog("clearTokens called")
        cachedAccessToken = nil
        cachedRefreshToken = nil
        deleteKeychainValue(account: Self.accessTokenAccount)
        deleteKeychainValue(account: Self.refreshTokenAccount)
    }

    func compareAndSet(
        compareRefreshToken: String,
        newRefreshToken: String?,
        newAccessToken: String?
    ) async {
        let current = keychainValue(account: Self.refreshTokenAccount)
        let matches = current == compareRefreshToken
        AuthManager.authLog("compareAndSet: matches=\(matches) newRefresh=\(newRefreshToken != nil ? "\(newRefreshToken!.prefix(10))..." : "nil") newAccess=\(newAccessToken != nil ? "\(newAccessToken!.prefix(10))..." : "nil")")
        guard matches else { return }
        // Don't let the StackClientApp's error cleanup path delete both tokens.
        // If both new values are nil, it means the refresh failed and the SDK wants
        // to clear the session. Preserve the refresh token so the user stays signed in.
        if newRefreshToken == nil && newAccessToken == nil {
            AuthManager.authLog("compareAndSet: blocked double-nil clear (preserving session)")
            return
        }
        await setTokens(accessToken: newAccessToken, refreshToken: newRefreshToken)
    }

    /// Read from keychain without blocking on a password prompt.
    /// Uses kSecUseAuthenticationUI = kSecUseAuthenticationUISkip to avoid UI prompts.
    private func keychainValueSafe(account: String) -> String? {
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
#else
        return nil
#endif
    }

    /// Write to keychain without blocking. If the keychain is locked, silently fails.
    private func setKeychainValueSafe(_ value: String, account: String) {
#if canImport(Security)
        guard let data = value.data(using: .utf8) else { return }
        // Try update first
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(lookup as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = lookup
            insert[kSecValueData as String] = data
            SecItemAdd(insert as CFDictionary, nil)
        }
#endif
    }

    private func keychainValue(account: String) -> String? {
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
#else
        return nil
#endif
    }

    private func setKeychainValue(_ value: String, account: String) {
#if canImport(Security)
        guard let data = value.data(using: .utf8) else { return }
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        let status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = lookup
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            if addStatus != errSecSuccess {
                AuthManager.authLog("keychain ADD failed: \(addStatus) account=\(account)")
            }
        } else if status != errSecSuccess {
            AuthManager.authLog("keychain UPDATE failed: \(status) account=\(account)")
        }
#endif
    }

    private func deleteKeychainValue(account: String) {
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
#endif
    }
}

actor LiveAuthClient: AuthClientProtocol {
    private let stack: StackClientApp

    init(
        tokenStore: any StackAuthTokenStoreProtocol
    ) {
        self.stack = StackClientApp(
            projectId: AuthEnvironment.stackProjectID,
            publishableClientKey: AuthEnvironment.stackPublishableClientKey,
            baseUrl: AuthEnvironment.stackBaseURL.absoluteString,
            tokenStore: .custom(tokenStore),
            noAutomaticPrefetch: true
        )
    }

    func signInWithCredential(email: String, password: String) async throws {
        try await stack.signInWithCredential(email: email, password: password)
    }

    func currentAccessToken() async throws -> String? {
        await stack.getAccessToken()
    }

    func currentUser() async throws -> CMUXAuthUser? {
        guard let payload = try await stack.getUser() else { return nil }
        return CMUXAuthUser(
            id: await payload.id,
            primaryEmail: await payload.primaryEmail,
            displayName: await payload.displayName
        )
    }

    func listTeams() async throws -> [AuthTeamSummary] {
        guard let user = try await stack.getUser() else {
            return []
        }

        let teams = try await user.listTeams()
        var summaries: [AuthTeamSummary] = []
        summaries.reserveCapacity(teams.count)
        for team in teams {
            summaries.append(
                AuthTeamSummary(
                    id: team.id,
                    displayName: await team.displayName
                )
            )
        }
        return summaries
    }

    func signOut() async throws {
        try await stack.signOut()
    }
}

private struct UITestAuthClient: AuthClientProtocol {
    let tokenStore: any StackAuthTokenStoreProtocol
    let user: CMUXAuthUser
    let teams: [AuthTeamSummary]

    static func makeIfEnabled(
        tokenStore: any StackAuthTokenStoreProtocol
    ) -> Self? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CMUX_UI_TEST_AUTH_STUB"] == "1" else {
            return nil
        }

        let user = CMUXAuthUser(
            id: environment["CMUX_UI_TEST_AUTH_USER_ID"] ?? "ui_test_user",
            primaryEmail: environment["CMUX_UI_TEST_AUTH_EMAIL"] ?? "uitest@cmux.dev",
            displayName: environment["CMUX_UI_TEST_AUTH_NAME"] ?? "UI Test"
        )
        let teams = [
            AuthTeamSummary(
                id: environment["CMUX_UI_TEST_AUTH_TEAM_ID"] ?? "team_alpha",
                displayName: environment["CMUX_UI_TEST_AUTH_TEAM_NAME"] ?? "Alpha"
            ),
        ]
        return Self(tokenStore: tokenStore, user: user, teams: teams)
    }

    func currentUser() async throws -> CMUXAuthUser? {
        let hasAccessToken = await tokenStore.currentAccessToken() != nil
        let hasRefreshToken = await tokenStore.currentRefreshToken() != nil
        return (hasAccessToken || hasRefreshToken) ? user : nil
    }

    func listTeams() async throws -> [AuthTeamSummary] {
        let hasAccessToken = await tokenStore.currentAccessToken() != nil
        let hasRefreshToken = await tokenStore.currentRefreshToken() != nil
        return (hasAccessToken || hasRefreshToken) ? teams : []
    }

    func currentAccessToken() async throws -> String? {
        await tokenStore.currentAccessToken()
    }
}
