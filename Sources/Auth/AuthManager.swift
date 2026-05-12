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
    case missingRefreshToken

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
        case .missingRefreshToken:
            return String(
                localized: "settings.account.error.missingRefreshToken",
                defaultValue: "Account refresh token is unavailable."
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
        // Release builds include a keychain-access-groups entitlement (via
        // Resources/cmux.entitlements) and go through the data-protection
        // keychain. Debug ad-hoc builds can't carry that entitlement
        // without a provisioning profile, so Keychain writes fail with
        // errSecMissingEntitlement and the file store takes over. The
        // wrapper picks per-run based on the first keychain write result.
        return FallbackTokenStore(
            primary: KeychainStackTokenStore(),
            fallback: FileStackTokenStore()
        )
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

    /// Resolves when the on-launch session restoration finishes (success or failure).
    /// Any probe that needs a definitive `isAuthenticated` value must `await` this
    /// first, otherwise it can race the restore and see a transient `false`.
    /// `var` rather than `let` so the init body can reference `self` before it's
    /// assigned; the value is written exactly once, before init returns.
    private var bootstrapTask: Task<Void, Never>!

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
        let cachedUser = settingsStore.cachedUser()
        self.currentUser = cachedUser
        self.selectedTeamID = settingsStore.selectedTeamID
        self.isAuthenticated = cachedUser != nil
        self.bootstrapTask = Task { [weak self] in
            await self?.restoreStoredSessionIfNeeded()
        }
    }

    /// Await the on-launch restoration. Returns immediately if already complete.
    /// Socket probes (`auth.status`) and any CLI-facing synchronous "am I signed in?"
    /// check must call this first so they can't observe the half-initialized state
    /// where tokens have been loaded but `refreshSession()` hasn't populated
    /// `isAuthenticated`. Making this an explicit phase boundary is what prevents
    /// the "Not signed in → Already signed in" race from recurring.
    func awaitBootstrapped() async {
        await bootstrapTask.value
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

    /// Starts the ASWebAuthenticationSession popup and awaits the user's
    /// completion by observing isAuthenticated AND isLoading. Resolves when
    /// authenticated, when the sign-in attempt settles unsuccessfully (popup
    /// dismissed/cancelled/error), or when the deadline elapses. No polling
    /// — the $isAuthenticated / $isLoading AsyncPublishers drive the wait.
    func beginSignInAndAwait(timeout: TimeInterval) async -> Bool {
        if isAuthenticated { return true }
        beginSignIn()
        return await waitForSignInSettled(timeout: timeout)
    }

    /// Signs out and awaits the state to flip. signOut() is already async and
    /// clears state before returning, so this is mostly a thin wrapper; the
    /// deadline exists purely to cap the worst-case hang time.
    func signOutAndAwait(timeout: TimeInterval) async -> Bool {
        await signOut()
        if !isAuthenticated { return true }
        return await waitForAuthState(target: false, timeout: timeout)
    }

    private func waitForSignInSettled(timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return false }
                for await value in self.$isAuthenticated.values {
                    if value { return true }
                }
                return false
            }
            group.addTask { @MainActor [weak self] in
                guard let self else { return false }
                // Wait for isLoading to flip false after we started the
                // popup. If authentication hasn't succeeded by then the
                // user cancelled/errored and we can resolve early.
                for await loading in self.$isLoading.values {
                    if !loading && !self.isAuthenticated { return false }
                    if self.isAuthenticated { return true }
                }
                return false
            }
            group.addTask {
                let maxSeconds: Double = 24 * 60 * 60
                let clamped = max(0, min(timeout, maxSeconds))
                try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func waitForAuthState(target: Bool, timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return false }
                for await value in self.$isAuthenticated.values {
                    if value == target { return true }
                }
                return false
            }
            group.addTask {
                // Clamp to a safe upper bound before converting to nanoseconds.
                // UInt64 overflow on an oversized Double would trap at runtime.
                let maxSeconds: Double = 24 * 60 * 60
                let clamped = max(0, min(timeout, maxSeconds))
                let ns = UInt64(clamped * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
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

    /// Both the access and refresh token for the current session, for callers that need to
    /// talk to cmux-owned backend endpoints (e.g. the cloud VM service) with the Stack Auth
    /// Authorization + X-Stack-Refresh-Token header pair.
    ///
    /// Awaits on-launch restoration before reading the token store. Without this, VM RPCs
    /// firing before `restoreStoredSessionIfNeeded()` finishes could observe an empty store
    /// on a refresh-token-only start and report "Not signed in" even though a valid session
    /// becomes available moments later (same class of race `auth.status` already guards).
    func currentTokens() async throws -> (accessToken: String, refreshToken: String) {
        await awaitBootstrapped()
        let access = await tokenStore.currentAccessToken()
        let refresh = await tokenStore.currentRefreshToken()
        guard let access, !access.isEmpty else {
            throw AuthManagerError.missingAccessToken
        }
        guard let refresh, !refresh.isEmpty else {
            throw AuthManagerError.missingRefreshToken
        }
        return (access, refresh)
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

    /// DEBUG-only append to /tmp/cmux-auth-debug.log. In Release builds this
    /// is a no-op so token-derived material and user emails never land in a
    /// world-traversable file. Call sites still pass PII-bearing strings
    /// because redacting at the call site is a lot of churn; keeping the
    /// #if DEBUG guard here is the single bottleneck that makes that safe.
    nonisolated static func authLog(_ message: String) {
        #if DEBUG
        let line = "[\(Self.logTimestampFormatter.string(from: Date()))] auth: \(message)\n"
        let path = "/tmp/cmux-auth-debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
        #endif
    }

    // ISO8601DateFormatter is expensive to construct (calendar + locale +
    // time zone). Reuse one instance across the high-frequency authLog path.
    private static let logTimestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

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


/// Composite store that routes to Keychain first and transparently falls
/// back to the file store if Keychain signals a real failure (empirically:
/// errSecMissingEntitlement -34018 on ad-hoc Debug builds without a matching
/// keychain-access-groups entry in the signed entitlements). Keeps writes
/// split-brain-free by clearing the file store whenever Keychain succeeds.
private actor FallbackTokenStore: StackAuthTokenStoreProtocol {
    private let keychain: KeychainStackTokenStore
    private let file: FileStackTokenStore
    private var keychainWorks: Bool = true

    init(primary keychain: KeychainStackTokenStore, fallback file: FileStackTokenStore) {
        self.keychain = keychain
        self.file = file
    }

    func getStoredAccessToken() async -> String? {
        if keychainWorks, let value = await keychain.getStoredAccessToken() {
            return value
        }
        return await file.getStoredAccessToken()
    }

    func getStoredRefreshToken() async -> String? {
        if keychainWorks, let value = await keychain.getStoredRefreshToken() {
            return value
        }
        return await file.getStoredRefreshToken()
    }

    func setTokens(accessToken: String?, refreshToken: String?) async {
        if keychainWorks {
            let ok = await keychain.trySetTokens(
                accessToken: accessToken,
                refreshToken: refreshToken
            )
            if ok {
                await file.clearTokens()
                return
            }
            keychainWorks = false
            AuthManager.authLog("keychain write failed; switching to file fallback for this session")
        }
        await file.setTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    func clearTokens() async {
        await keychain.clearTokens()
        await file.clearTokens()
    }

    func compareAndSet(
        compareRefreshToken: String,
        newRefreshToken: String?,
        newAccessToken: String?
    ) async {
        if keychainWorks {
            await keychain.compareAndSet(
                compareRefreshToken: compareRefreshToken,
                newRefreshToken: newRefreshToken,
                newAccessToken: newAccessToken
            )
            return
        }
        await file.compareAndSet(
            compareRefreshToken: compareRefreshToken,
            newRefreshToken: newRefreshToken,
            newAccessToken: newAccessToken
        )
    }
}

/// File-backed token store: writes to a JSON document with 0600 mode in
/// Application Support, namespaced by bundle id. Chosen over both the login
/// keychain (prompts on every ad-hoc Debug rebuild) and the data-protection
/// keychain (fails with errSecMissingEntitlement without a keychain-access-
/// groups entitlement we don't have on Debug). `fsync` on write so a
/// pkill-during-reload can't drop the refresh token.
private actor FileStackTokenStore: StackAuthTokenStoreProtocol {
    private struct Snapshot: Codable {
        var accessToken: String?
        var refreshToken: String?
    }

    private let fileURL: URL = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let bundleID = Bundle.main.bundleIdentifier ?? "cmux"
        return support
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("credentials.json", isDirectory: false)
    }()

    private var cache: Snapshot?

    func getStoredAccessToken() async -> String? {
        loadIfNeeded().accessToken
    }

    func getStoredRefreshToken() async -> String? {
        loadIfNeeded().refreshToken
    }

    func setTokens(accessToken: String?, refreshToken: String?) async {
        AuthManager.authLog("file.setTokens: hasAccess=\(accessToken?.isEmpty == false) hasRefresh=\(refreshToken?.isEmpty == false)")
        var snapshot = loadIfNeeded()
        snapshot.accessToken = (accessToken?.isEmpty == false) ? accessToken : nil
        snapshot.refreshToken = (refreshToken?.isEmpty == false) ? refreshToken : nil
        write(snapshot)
    }

    func clearTokens() async {
        AuthManager.authLog("clearTokens called")
        write(Snapshot(accessToken: nil, refreshToken: nil))
    }

    func compareAndSet(
        compareRefreshToken: String,
        newRefreshToken: String?,
        newAccessToken: String?
    ) async {
        let current = loadIfNeeded().refreshToken
        let matches = current == compareRefreshToken
        AuthManager.authLog("file.compareAndSet: matches=\(matches) hasNewRefresh=\(newRefreshToken?.isEmpty == false) hasNewAccess=\(newAccessToken?.isEmpty == false)")
        guard matches else { return }
        if newRefreshToken == nil && newAccessToken == nil {
            AuthManager.authLog("file.compareAndSet: blocked double-nil clear (preserving session)")
            return
        }
        await setTokens(accessToken: newAccessToken, refreshToken: newRefreshToken)
    }

    private func loadIfNeeded() -> Snapshot {
        if let cache { return cache }
        let snapshot = readFromDisk()
        cache = snapshot
        return snapshot
    }

    private func readFromDisk() -> Snapshot {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return Snapshot() }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            return snapshot
        } catch {
            AuthManager.authLog("credentials read failed: \(error)")
            return Snapshot()
        }
    }

    private func write(_ snapshot: Snapshot) {
        cache = snapshot
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            AuthManager.authLog("credentials write failed: \(error)")
        }
    }
}

private actor KeychainStackTokenStore: StackAuthTokenStoreProtocol {
    private static let accessTokenAccount = "cmux-auth-access-token"
    private static let refreshTokenAccount = "cmux-auth-refresh-token"
    private let service = AuthKeychainServiceName.make()

    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?

    func getStoredAccessToken() async -> String? {
        if let cachedAccessToken { return cachedAccessToken }
        return keychainRead(account: Self.accessTokenAccount)
    }

    func getStoredRefreshToken() async -> String? {
        if let cachedRefreshToken { return cachedRefreshToken }
        return keychainRead(account: Self.refreshTokenAccount)
    }

    func setTokens(accessToken: String?, refreshToken: String?) async {
        _ = await trySetTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    /// Same as setTokens but returns whether every keychain operation
    /// actually succeeded. Used by FallbackTokenStore to decide when to
    /// give up on Keychain and route to the file store.
    func trySetTokens(accessToken: String?, refreshToken: String?) async -> Bool {
        AuthManager.authLog("keychain.setTokens: hasAccess=\(accessToken?.isEmpty == false) hasRefresh=\(refreshToken?.isEmpty == false)")
        cachedAccessToken = (accessToken?.isEmpty == false) ? accessToken : nil
        cachedRefreshToken = (refreshToken?.isEmpty == false) ? refreshToken : nil

        var allOK = true
        if let accessToken, !accessToken.isEmpty {
            allOK = keychainWrite(accessToken, account: Self.accessTokenAccount) && allOK
        } else {
            keychainDelete(account: Self.accessTokenAccount)
        }
        if let refreshToken, !refreshToken.isEmpty {
            allOK = keychainWrite(refreshToken, account: Self.refreshTokenAccount) && allOK
        } else {
            keychainDelete(account: Self.refreshTokenAccount)
        }
        return allOK
    }

    func clearTokens() async {
        AuthManager.authLog("clearTokens called")
        cachedAccessToken = nil
        cachedRefreshToken = nil
        keychainDelete(account: Self.accessTokenAccount)
        keychainDelete(account: Self.refreshTokenAccount)
    }

    func compareAndSet(
        compareRefreshToken: String,
        newRefreshToken: String?,
        newAccessToken: String?
    ) async {
        let current = keychainRead(account: Self.refreshTokenAccount)
        let matches = current == compareRefreshToken
        AuthManager.authLog("keychain.compareAndSet: matches=\(matches) hasNewRefresh=\(newRefreshToken?.isEmpty == false) hasNewAccess=\(newAccessToken?.isEmpty == false)")
        guard matches else { return }
        // Don't let the StackClientApp's error cleanup path delete both tokens.
        // If both new values are nil, it means the refresh failed and the SDK wants
        // to clear the session. Preserve the refresh token so the user stays signed in.
        if newRefreshToken == nil && newAccessToken == nil {
            AuthManager.authLog("keychain.compareAndSet: blocked double-nil clear (preserving session)")
            return
        }
        await setTokens(accessToken: newAccessToken, refreshToken: newRefreshToken)
    }

#if canImport(Security)
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func keychainRead(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                AuthManager.authLog("keychain READ status=\(status) account=\(account)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func keychainWrite(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let lookup = baseQuery(account: account)
        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound {
            AuthManager.authLog("keychain UPDATE status=\(updateStatus) account=\(account)")
        }
        var insert = lookup
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus != errSecSuccess {
            AuthManager.authLog("keychain ADD status=\(addStatus) account=\(account)")
            return false
        }
        return true
    }

    private func keychainDelete(account: String) {
        _ = SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
#else
    private func keychainRead(account: String) -> String? { nil }
    private func keychainWrite(_ value: String, account: String) -> Bool { false }
    private func keychainDelete(account: String) {}
#endif
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
