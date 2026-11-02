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
        let directory = homeDirectory
            .appendingPathComponent("Library/Application Support/cmux", isDirectory: true)
            .appendingPathComponent(bundleID ?? "cmux", isDirectory: true)
        return authStorageProject.map { directory.appendingPathComponent($0, isDirectory: true) } ?? directory
    }

    func authDefaultsKey(_ key: String) -> String {
        authStorageProject.map { "\(key).\($0)" } ?? key
    }

    // The first signed DEV staging launch must not read production tokens or
    // prime its cached user/team. A stable namespace preserves staging sign-in
    // on subsequent launches and leaves the old production session untouched.
    private var authStorageProject: String? {
        !isDebugBuild && bundleID == "com.cmuxterm.app.debug.next" && !isProductionAuth
            && stackProjectID == Self.developmentProjectID ? stackProjectID : nil
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
                               isDebugBuild: Bool) -> CloudConfiguration {
        // NEXT DEV is a signed Release compile, not a DEBUG build. Its Worker
        // accepts staging Stack tokens. Keep this channel's endpoints fixed so
        // inherited environment variables cannot redirect its credentials.
        if !isDebugBuild, bundleID == "com.cmuxterm.app.debug.next" {
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
        if production {
            return CloudConfiguration(
                backend: .production, apiBaseURL: productionOrigin, authWebOrigin: productionOrigin,
                stackBaseURL: stackBase, stackProjectID: productionProjectID, stackPublishableClientKey: productionClientKey,
                isProductionAuth: true, callbackScheme: scheme, bundleID: bundleID, isDebugBuild: isDebugBuild)
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
            // CMUX_NEXT_CLOUD_LINK survives the launch: the app unsets every inherited
            // CMUX_* variable but CMUX_NEXT_* (LaunchIdentity.stripInheritedEnvironment);
            // CMUX_CLOUD_LINK works only when baked into the bundle's LSEnvironment.
            // The app-server link is the default; `legacy` keeps the classic one.
            linkSource: (value("CMUX_NEXT_CLOUD_LINK") ?? value("CMUX_CLOUD_LINK"))?.lowercased() == "legacy" ? .legacy : .appServer)
    }

    /// This process's configuration.
    /// The API Worker (`/v1/read`, `/v1/ops`, `/v1/auth/*`): production
    /// auth uses cloud-api.cmux.dev, signed NEXT DEV and every other
    /// development build the development Worker. The
    /// `CMUX_NEXT_FEED_API_URL` override is honored in debug builds only, so
    /// a release build never sends a credential to another origin.
    public func ownerAPIBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if !isDebugBuild, bundleID == "com.cmuxterm.app.debug.next" { return Self.developmentWorkerOrigin }
        if isDebugBuild, let raw = environment["CMUX_NEXT_FEED_API_URL"], let url = URL(string: raw) { return url }
        // Non-production builds sign in on staging, whose Stack tokens the development Worker accepts.
        guard isProductionAuth else { return Self.developmentWorkerOrigin }
        // A constant https literal (CloudCrashLiteralTests parses it); /dev/null stands in.
        return URL(string: "https://cloud-api.cmux.dev") ?? Self.inertURL
    }

    /// The API a guest link's owner token comes from. The daemon makes each build's links in its
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

    public static func current(bundle: Bundle = .main, isDebugBuild: Bool) -> CloudConfiguration {
        let bundled = bundle.object(forInfoDictionaryKey: "LSEnvironment") as? [String: String] ?? [:]
        return resolve(bundleID: bundle.bundleIdentifier, bundled: bundled,
                       process: ProcessInfo.processInfo.environment, isDebugBuild: isDebugBuild)
    }

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
