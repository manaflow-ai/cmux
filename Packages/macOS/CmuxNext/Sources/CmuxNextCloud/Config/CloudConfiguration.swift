public import Foundation

/// Where this build's Cloud lives: the web API origin, the Stack project, the
/// token Keychain service, and the sign-in callback scheme.
///
/// Values come from the bundle's `Info.plist` `LSEnvironment` (what
/// `scripts/reload.sh` bakes into tagged builds), then the process
/// environment. Release builds always use production. A Debug build built
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
        /// `/api/vm` attach endpoint and a `cmux-tui remote connect` process
        /// (frozen, contract 2.5).
        case legacy
        /// The Cloud app server's `cloud.machine.connect` carrier socket
        /// (contract 2.3). Debug builds with `CMUX_CLOUD_LINK=app` only,
        /// until the machine list comes from the app server too.
        case appServer
    }

    /// Existing Stack token Keychain service (`<bundle id>.auth`); changing it
    /// signs every user out (inventory.md "Auth").
    public var keychainService: String {
        guard let bundleID, !bundleID.isEmpty else { return "com.cmuxterm.app.auth" }
        return "\(bundleID).auth"
    }

    /// The file-fallback token store directory the old app used.
    public var credentialsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/cmux", isDirectory: true)
            .appendingPathComponent(bundleID ?? "cmux", isDirectory: true)
    }

    /// `<scheme>://auth-callback`. `resolve` accepts only a scheme that forms this URL;
    /// /dev/null stands in for a hand-built configuration with one that does not.
    public var callbackURL: URL { URL(string: "\(callbackScheme)://auth-callback") ?? Self.inertURL }

    /// Stands in where a literal URL failed to parse (tests parse every literal).
    static let inertURL = URL(fileURLWithPath: "/dev/null")
    static let productionOrigin = URL(string: "https://cmux.com") ?? inertURL
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
        let devBackend = value("CMUX_DEV_BACKEND_URL").flatMap(URL.init(string:))
        let api = value("CMUX_VM_API_BASE_URL").flatMap(URL.init(string:))
            ?? value("CMUX_API_BASE_URL").flatMap(URL.init(string:))
            ?? devBackend
            ?? URL(string: "http://localhost:\(value("CMUX_PORT") ?? "3777")")
            ?? localDevelopmentOrigin
        let web = value("CMUX_AUTH_WWW_ORIGIN").flatMap(URL.init(string:)) ?? devBackend ?? api
        let backend: Backend = isLoopback(api) && devBackend == nil ? .localOnly(api) : .development(api)
        return CloudConfiguration(
            backend: backend, apiBaseURL: api, authWebOrigin: web, stackBaseURL: stackBase,
            stackProjectID: value("CMUX_STACK_PROJECT_ID") ?? developmentProjectID,
            stackPublishableClientKey: value("CMUX_STACK_PUBLISHABLE_CLIENT_KEY") ?? developmentClientKey,
            isProductionAuth: false, callbackScheme: scheme, bundleID: bundleID, isDebugBuild: isDebugBuild,
            linkSource: value("CMUX_CLOUD_LINK")?.lowercased() == "app" ? .appServer : .legacy)
    }

    /// This process's configuration.
    /// The API Worker (`/v1/read`, `/v1/ops`, `/v1/auth/*`): production
    /// auth uses cloud-api.cmux.dev, everything else the staging Worker. The
    /// `CMUX_NEXT_FEED_API_URL` override is honored in debug builds only, so
    /// a release build never sends a credential to another origin.
    public func ownerAPIBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if isDebugBuild, let raw = environment["CMUX_NEXT_FEED_API_URL"], let url = URL(string: raw) { return url }
        // crash-allow: both operands are constant, valid https URL literals, so the parse cannot fail
        return URL(string: isProductionAuth ? "https://cloud-api.cmux.dev" : "https://cloud-api-staging.cmux.dev")!
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
