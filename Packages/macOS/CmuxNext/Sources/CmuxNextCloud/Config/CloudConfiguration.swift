public import Foundation

/// Where this build's Cloud lives: the web API origin, the Stack project, the
/// token Keychain service, and the sign-in callback scheme.
///
/// Values come from the bundle's `Info.plist` `LSEnvironment` (what
/// `scripts/reload.sh` bakes into tagged builds), then the process
/// environment. Release builds use production except the signed NEXT DEV
/// channel, which uses the development Worker and staging sign-in. A Debug build built
/// without `--direct-backend` points at a loopback origin with no server;
/// ``backend`` says so, so Cloud actions can explain how to fix the build
/// instead of timing out.
public struct CloudConfiguration: Sendable, Equatable {
    public enum Backend: Sendable, Equatable {
        /// Production (`https://cmux.com`).
        case production
        /// The tag's shared development stack (`--direct-backend`).
        case development(URL)
        /// A loopback origin: `scripts/reload.sh` local backend mode.
        case localOnly(URL)
    }

    public var backend: Backend
    public var apiBaseURL: URL
    /// Origin of the web sign-in pages (`handler/native-sign-in`).
    public var authWebOrigin: URL
    public var stackBaseURL: URL
    public var stackProjectID: String
    public var stackPublishableClientKey: String
    public var isProductionAuth: Bool
    public var callbackScheme: String
    public var bundleID: String?
    public var isDebugBuild: Bool
    /// Where a Cloud machine's link socket comes from.
    public var linkSource: LinkSource = .legacy

    public enum LinkSource: Sendable, Equatable {
        /// `/api/vm` list, create and attach endpoint and a `cmux-tui remote
        /// connect` process (frozen, contract 2.5). The default until the
        /// first-party app packages ship in the bundle (cx-t2rz), except NEXT DEV.
        case legacy
        /// The Cloud app server (contract 2.1, 2.3): the machine list,
        /// create and the `cloud.machine.connect` carrier socket, all on the
        /// cmux-next API Worker through the host credential relay (cx-t2rz).
        /// Signed NEXT DEV and every Debug build; `CMUX_NEXT_CLOUD_LINK=legacy` (launch env) or
        /// `CMUX_CLOUD_LINK=legacy` (baked) keeps a Debug build on the classic link.
        case appServer
    }

    /// Existing Stack token Keychain service (`<bundle id>.auth`). Signed NEXT
    /// DEV scopes staging tokens separately so it never restores its old production session.
    public var keychainService: String {
        guard let bundleID, !bundleID.isEmpty else { return "com.cmuxterm.app.auth" }
        let service = "\(bundleID).auth"
        return authStorageProject.map { "\(service).\($0)" } ?? service
    }

    /// The file-fallback token store directory the old app used.
    public var credentialsDirectory: URL {
        credentialsDirectory(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    func credentialsDirectory(homeDirectory: URL) -> URL {
        let directory = Self.bundleSupportDirectory(homeDirectory: homeDirectory, bundleID: bundleID ?? "cmux")
        return authStorageProject.map { directory.appendingPathComponent($0, isDirectory: true) } ?? directory
    }

    /// A bundle's directory under the cmux Application Support folder (its file token store's).
    static func bundleSupportDirectory(homeDirectory: URL, bundleID: String) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/cmux", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
    }

    func authDefaultsKey(_ key: String) -> String {
        authStorageProject.map { "\(key).\($0)" } ?? key
    }

    // The first signed DEV staging launch must not read production tokens or
    // prime its cached user/team. A stable namespace preserves staging sign-in
    // on subsequent launches and leaves the old production session untouched.
    // Signed in as the NIGHTLY account (``DevAccount/nightly``), DEV keeps that production session in its
    // own production namespace, apart from both its staging session and the pre-staging one.
    private var authStorageProject: String? {
        guard !isDebugBuild, bundleID == Self.signedDEVBundleID else { return nil }
        switch (isProductionAuth, stackProjectID) {
        case (false, Self.developmentProjectID), (true, Self.productionProjectID): return stackProjectID
        default: return nil
        }
    }

    static let signedDEVBundleID = "com.cmuxterm.app.debug.next"

    /// The account signed NEXT DEV signs in as.
    public enum DevAccount: String, Sendable, Equatable {
        /// The staging agent test account (the seeded sign-in file CI and agents launch with).
        case staging
        /// The person's own production account, handed over by a running cmux NIGHTLY
        /// (``adoptsNightlySession``).
        case nightly
    }

    /// Whether this build adopts cmux NIGHTLY's session: a signed NEXT DEV build on the production
    /// account. It asks a running NIGHTLY over NIGHTLY's control socket (`auth.session.handoff`) and keeps
    /// the session in memory only, never in its own Keychain item or a file.
    public var adoptsNightlySession: Bool {
        !isDebugBuild && bundleID == Self.signedDEVBundleID && isProductionAuth
    }

    /// The account a signed NEXT DEV launch uses: the chosen one, except ``DevAccount/nightly`` while no
    /// cmux NIGHTLY runs to hand its session over, which is ``DevAccount/staging``. The choice itself is
    /// kept, so the next launch with NIGHTLY running is on the NIGHTLY account again.
    public static func launchAccount(chosen: DevAccount, nightlyIsRunning: () -> Bool) -> DevAccount {
        chosen == .nightly && !nightlyIsRunning() ? .staging : chosen
    }

    static let devAccountDefaultsKey = "cmux.next.dev.account"

    /// Signed NEXT DEV's account: the launch's `CMUX_NEXT_DEV_ACCOUNT` (`nightly` or `staging`), kept in
    /// `defaults` so an update's relaunch, which has no launch environment, keeps it; else the one a
    /// launch kept; else ``DevAccount/staging``.
    public static func devAccount(environment: [String: String], defaults: UserDefaults) -> DevAccount {
        let raw = environment["CMUX_NEXT_DEV_ACCOUNT"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let account = raw.flatMap(DevAccount.init(rawValue:)) {
            defaults.set(account.rawValue, forKey: devAccountDefaultsKey)
            return account
        }
        return defaults.string(forKey: devAccountDefaultsKey).flatMap(DevAccount.init(rawValue:)) ?? .staging
    }

    /// `<scheme>://auth-callback`. `resolve` accepts only a scheme that forms this URL;
    /// /dev/null stands in for a hand-built configuration with one that does not.
    public var callbackURL: URL { URL(string: "\(callbackScheme)://auth-callback") ?? Self.inertURL }

    /// Stands in where a literal URL failed to parse (tests parse every literal).
    static let inertURL = URL(fileURLWithPath: "/dev/null")
    static let productionOrigin = URL(string: "https://cmux.com") ?? inertURL
    static let stagingOrigin = URL(string: "https://cmux-staging.vercel.app") ?? inertURL
    static let developmentWorkerOrigin = URL(string: "https://cmux-api-development.debussy.workers.dev") ?? inertURL
    static let stackOrigin = URL(string: "https://api.stack-auth.com") ?? inertURL
    static let localDevelopmentOrigin = URL(string: "http://localhost:3777") ?? inertURL
    static let developmentProjectID = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
    static let developmentClientKey = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"
    static let productionProjectID = "9790718f-14cd-4f7e-824d-eaf527a82b82"
    /// Empty on purpose: the production project does not require a publishable
    /// key, and a shipped key would break sign-in once its key set is revoked.
    static let productionClientKey = ""

    /// Pure resolution. `bundled` is the bundle's `LSEnvironment`; it wins
    /// over `process` because a launch from a shell must not redirect a
    /// tagged build to another backend.
    public static func resolve(bundleID: String?, bundled: [String: String], process: [String: String],
                               isDebugBuild: Bool, devAccount: DevAccount = .staging) -> CloudConfiguration {
        // NEXT DEV is a signed Release compile, not a DEBUG build. Its Worker
        // accepts staging Stack tokens. Keep this channel's endpoints fixed so
        // inherited environment variables cannot redirect its credentials: it
        // has two fixed configurations, staging and, signed in as the NIGHTLY
        // account, production (``DevAccount``).
        if !isDebugBuild, bundleID == signedDEVBundleID, devAccount == .nightly {
            return CloudConfiguration(
                backend: .production, apiBaseURL: productionOrigin, authWebOrigin: productionOrigin,
                stackBaseURL: stackOrigin, stackProjectID: productionProjectID, stackPublishableClientKey: productionClientKey,
                isProductionAuth: true, callbackScheme: "cmux-next-dev", bundleID: bundleID, isDebugBuild: false,
                linkSource: .appServer)
        }
        if !isDebugBuild, bundleID == signedDEVBundleID {
            return CloudConfiguration(
                backend: .development(stagingOrigin), apiBaseURL: stagingOrigin, authWebOrigin: stagingOrigin,
                stackBaseURL: stackOrigin, stackProjectID: developmentProjectID, stackPublishableClientKey: developmentClientKey,
                isProductionAuth: false, callbackScheme: "cmux-next-dev", bundleID: bundleID, isDebugBuild: false,
                linkSource: .appServer)
        }
        let value = { (key: String) -> String? in
            let raw = bundled[key] ?? process[key]
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        let production = !isDebugBuild || value("CMUX_AUTH_ENVIRONMENT")?.lowercased() == "production"
        let tag = value("CMUX_TAG").flatMap(sanitizedSchemeTag)
        // A scheme that cannot form `<scheme>://auth-callback` is ignored (it trapped at sign-in).
        let scheme = value("CMUX_AUTH_CALLBACK_SCHEME").flatMap { URL(string: "\($0)://auth-callback") == nil ? nil : $0 }
            ?? (isDebugBuild ? (tag.map { "cmux-dev-\($0)" } ?? "cmux-dev") : defaultScheme(bundleID))
        let stackBase = value("CMUX_STACK_BASE_URL").flatMap(URL.init(string:)) ?? stackOrigin
        // CMUX_NEXT_CLOUD_LINK survives the launch: the app unsets every inherited
        // CMUX_* variable but CMUX_NEXT_* (LaunchIdentity.stripInheritedEnvironment);
        // CMUX_CLOUD_LINK works only when baked into the bundle's LSEnvironment.
        // The app-server link (NEXT Cloud through the owner API) is the default in every
        // environment, production included; `legacy` keeps the classic one as the escape hatch.
        let linkSource: LinkSource = (value("CMUX_NEXT_CLOUD_LINK") ?? value("CMUX_CLOUD_LINK"))?.lowercased() == "legacy" ? .legacy : .appServer
        if production {
            return CloudConfiguration(
                backend: .production, apiBaseURL: productionOrigin, authWebOrigin: productionOrigin,
                stackBaseURL: stackBase, stackProjectID: productionProjectID, stackPublishableClientKey: productionClientKey,
                isProductionAuth: true, callbackScheme: scheme, bundleID: bundleID, isDebugBuild: isDebugBuild,
                linkSource: linkSource)
        }
        // Every non-production build (Debug, tagged fleet builds) signs in on staging and uses the
        // new cloud with no launch environment. Tagged builds bake loopback origins for a local
        // web server that is usually not running, so a loopback value is taken only when the
        // launch asks for it (`CMUX_NEXT_CLOUD_BACKEND=local`); any other origin still overrides.
        let wantsLocal = process["CMUX_NEXT_CLOUD_BACKEND"]?.lowercased() == "local"
        let origin = { (key: String) -> URL? in
            value(key).flatMap(URL.init(string:)).flatMap { wantsLocal || !isLoopback($0) ? $0 : nil }
        }
        let devBackend = origin("CMUX_DEV_BACKEND_URL")
        let api = origin("CMUX_VM_API_BASE_URL") ?? origin("CMUX_API_BASE_URL") ?? devBackend
            ?? (wantsLocal ? URL(string: "http://localhost:\(value("CMUX_PORT") ?? "3777")") : nil)
            ?? stagingOrigin
        let web = origin("CMUX_AUTH_WWW_ORIGIN") ?? devBackend ?? api
        let backend: Backend = isLoopback(api) && devBackend == nil ? .localOnly(api) : .development(api)
        return CloudConfiguration(
            backend: backend, apiBaseURL: api, authWebOrigin: web, stackBaseURL: stackBase,
            stackProjectID: value("CMUX_STACK_PROJECT_ID") ?? developmentProjectID,
            stackPublishableClientKey: value("CMUX_STACK_PUBLISHABLE_CLIENT_KEY") ?? developmentClientKey,
            isProductionAuth: false, callbackScheme: scheme, bundleID: bundleID, isDebugBuild: isDebugBuild,
            linkSource: linkSource)
    }

    /// This process's configuration.
    /// The API Worker (`/v1/read`, `/v1/ops`, `/v1/auth/*`): production
    /// auth uses cloud-api.cmux.dev, signed NEXT DEV and every other
    /// development build the development Worker. The
    /// `CMUX_NEXT_FEED_API_URL` override is honored in debug builds only, so
    /// a release build never sends a credential to another origin.
    public func ownerAPIBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if !isDebugBuild, bundleID == Self.signedDEVBundleID, !isProductionAuth { return Self.developmentWorkerOrigin }
        if isDebugBuild, let raw = environment["CMUX_NEXT_FEED_API_URL"], let url = URL(string: raw) { return url }
        // Non-production builds sign in on staging, whose Stack tokens the development Worker accepts.
        guard isProductionAuth else { return Self.developmentWorkerOrigin }
        // A constant https literal (CloudCrashLiteralTests parses it); /dev/null stands in.
        return URL(string: "https://cloud-api.cmux.dev") ?? Self.inertURL
    }

    /// The platform Worker that serves a machine's relay-first chat (``CloudRelayChat``, cmux-platform
    /// `MachineRelay`), the environment ``ownerAPIBaseURL(environment:)`` signs in to: production's for a
    /// production sign-in, else development's. `CMUX_NEXT_RELAY_API_URL` is honored in debug builds only.
    public func relayAPIBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if isDebugBuild, let raw = environment["CMUX_NEXT_RELAY_API_URL"], let url = URL(string: raw) { return url }
        guard isProductionAuth else {
            return URL(string: "https://cmux-platform-development.debussy.workers.dev") ?? Self.inertURL
        }
        return URL(string: "https://cmux-platform-production.debussy.workers.dev") ?? Self.inertURL
    }

    /// The API a guest link's owner token comes from when the daemon does not name its room's
    /// (`agent-session-share-room`, an older daemon). The daemon makes each build's links in its
    /// room (cmux-tui share_room.rs: DEV the development room), and a room takes only its own
    /// environment's install tokens. A debug build signs in to the staging Worker
    /// (``ownerAPIBaseURL(environment:)``), so its links mint from the development Worker; with
    /// `CMUX_NEXT_FEED_API_URL` set, the owner API is the one named, as for every other call.
    public func shareAPIBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        guard isDebugBuild, !isProductionAuth, environment["CMUX_NEXT_FEED_API_URL"] == nil else {
            return ownerAPIBaseURL(environment: environment)
        }
        return URL(string: "https://cmux-api-development.debussy.workers.dev") ?? Self.inertURL
    }

    /// Whether a guest link's owner token may come from `api`, the API the daemon's share room names
    /// (`agent-session-share-room`, cmux#31372). A release build takes only a cmux API, so the owner's
    /// credentials never reach another origin; a debug build takes any https origin. Only a bare origin (no
    /// credentials, port, path, query or fragment) is taken: an install is kept per host (`install-share-<host>`).
    public func acceptsShareAPI(_ api: URL) -> Bool {
        guard api.scheme?.lowercased() == "https", let host = api.host?.lowercased(), !host.isEmpty, api.user == nil, api.password == nil,
              api.path.isEmpty || api.path == "/", api.query == nil, api.fragment == nil else { return false }
        return api.port == nil && (isDebugBuild || Self.shareAPIHosts.contains(host))
    }

    /// The cmux APIs a share room takes tokens from (cmux-tui `platform::share_owner_api`).
    static let shareAPIHosts: Set<String> = ["cloud-api.cmux.dev", "cloud-api-staging.cmux.dev", "cmux-api-development.debussy.workers.dev"]

    /// Whether this compile has the bench hooks (`reload.sh --config bench`: `CMUX_BENCH_HOOKS`, never in a
    /// shipped app). With them, a `cap<sha10>` capture build's Cloud is configured as a Debug build's (``isCaptureBuild(bundleID:benchHooks:)``).
    public static var benchHooksCompiled: Bool {
        #if CMUX_BENCH_HOOKS
        true
        #else
        false
        #endif
    }

    /// `benchHooks`: whether this compile has the bench hooks (``benchHooksCompiled`` unless a test says).
    /// `nightlyIsRunning`: whether cmux NIGHTLY runs now; signed NEXT DEV on the ``DevAccount/nightly``
    /// account falls back to staging, as before that account existed, when it does not
    /// (``launchAccount(chosen:nightlyIsRunning:)``).
    public static func current(bundle: Bundle = .main, isDebugBuild: Bool, benchHooks: Bool = benchHooksCompiled,
                               nightlyIsRunning: () -> Bool) -> CloudConfiguration {
        let bundled = bundle.object(forInfoDictionaryKey: "LSEnvironment") as? [String: String] ?? [:]
        let debug = isDebugBuild || isCaptureBuild(bundleID: bundle.bundleIdentifier, benchHooks: benchHooks)
        let process = ProcessInfo.processInfo.environment
        let account = !debug && bundle.bundleIdentifier == signedDEVBundleID
            ? launchAccount(chosen: devAccount(environment: process, defaults: .standard), nightlyIsRunning: nightlyIsRunning)
            : .staging
        return resolve(bundleID: bundle.bundleIdentifier, bundled: bundled, process: process, isDebugBuild: debug,
                       devAccount: account)
    }

    /// Whether this is a PR capture's Release build: the bench configuration (`CMUX_BENCH_HOOKS`, which the
    /// release and nightly pipelines refuse to ship, scripts/cmux-next/check-no-bench-hooks.sh) of the tag
    /// `cap<sha10>` (cmuxterm-hq build-fleet/pr-capture `--release`). Its Cloud is configured as a Debug build's:
    /// the development backend and the capture account's automatic sign-in, so a capture can drive the Release
    /// paths (`DevTools.isEnabled` false, which this does not change) against a test account. A shipped build
    /// has neither the hooks nor that bundle identifier, so it keeps production.
    public static func isCaptureBuild(bundleID: String?, benchHooks: Bool) -> Bool {
        guard benchHooks, let bundleID, bundleID.hasPrefix(captureBundlePrefix) else { return false }
        let tag = bundleID.dropFirst(captureBundlePrefix.count)
        return tag.count == 10 && tag.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    static let captureBundlePrefix = "com.cmuxterm.app.debug.cap"

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    static func defaultScheme(_ bundleID: String?) -> String {
        switch bundleID {
        case "com.cmuxterm.app.nightly": "cmux-nightly"
        case "com.cmuxterm.app.rc": "cmux-rc"
        default: "cmux"
        }
    }

    /// `[a-z0-9]` runs joined by single hyphens, as the old app registered.
    static func sanitizedSchemeTag(_ raw: String) -> String? {
        var result = ""
        var lastHyphen = false
        for scalar in raw.lowercased().unicodeScalars {
            if (97...122).contains(scalar.value) || (48...57).contains(scalar.value) {
                result.unicodeScalars.append(scalar)
                lastHyphen = false
            } else if !lastHyphen {
                result.append("-")
                lastHyphen = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Hosted sign-in entry: `handler/native-sign-in` wraps Stack sign-in and
    /// returns to `<scheme>://auth-callback` through `handler/after-sign-in`.
    public func signInURL(callbackState: String?) -> URL {
        // URLComponents of a parsed URL always forms a URL again; without one, the bare entry page.
        let entryPage = authWebOrigin.appendingPathComponent("handler/native-sign-in")
        var callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        if let callbackState { callback?.queryItems = [URLQueryItem(name: "cmux_auth_state", value: callbackState)] }
        var after = URLComponents(url: authWebOrigin.appendingPathComponent("handler/after-sign-in"), resolvingAgainstBaseURL: false)
        after?.queryItems = callback?.url.map { [URLQueryItem(name: "native_app_return_to", value: $0.absoluteString)] }
        var entry = URLComponents(url: entryPage, resolvingAgainstBaseURL: false)
        entry?.queryItems = after?.url.map { [URLQueryItem(name: "after_auth_return_to", value: $0.absoluteString)] }
        return entry?.url ?? entryPage
    }
}
