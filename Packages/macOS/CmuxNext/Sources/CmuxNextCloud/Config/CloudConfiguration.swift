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

    public var callbackURL: URL { URL(string: "\(callbackScheme)://auth-callback")! }

    static let productionOrigin = URL(string: "https://cmux.com")!
    static let developmentProjectID = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
    static let developmentClientKey = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"
    static let productionProjectID = "9790718f-14cd-4f7e-824d-eaf527a82b82"
    static let productionClientKey = "pck_kzj80gx4mh2jrzn1cx6y5e8jk0kwa01vkevh2p9zd4twr"

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
        let scheme = value("CMUX_AUTH_CALLBACK_SCHEME")
            ?? (isDebugBuild ? (tag.map { "cmux-dev-\($0)" } ?? "cmux-dev") : defaultScheme(bundleID))
        let stackBase = value("CMUX_STACK_BASE_URL").flatMap(URL.init(string:)) ?? URL(string: "https://api.stack-auth.com")!
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
            ?? URL(string: "http://localhost:\(value("CMUX_PORT") ?? "3777")")!
        let web = value("CMUX_AUTH_WWW_ORIGIN").flatMap(URL.init(string:)) ?? devBackend ?? api
        let backend: Backend = isLoopback(api) && devBackend == nil ? .localOnly(api) : .development(api)
        return CloudConfiguration(
            backend: backend, apiBaseURL: api, authWebOrigin: web, stackBaseURL: stackBase,
            stackProjectID: value("CMUX_STACK_PROJECT_ID") ?? developmentProjectID,
            stackPublishableClientKey: value("CMUX_STACK_PUBLISHABLE_CLIENT_KEY") ?? developmentClientKey,
            isProductionAuth: false, callbackScheme: scheme, bundleID: bundleID, isDebugBuild: isDebugBuild)
    }

    /// This process's configuration.
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
        var callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)!
        if let callbackState { callback.queryItems = [URLQueryItem(name: "cmux_auth_state", value: callbackState)] }
        var after = URLComponents(url: authWebOrigin.appendingPathComponent("handler/after-sign-in"), resolvingAgainstBaseURL: false)!
        after.queryItems = [URLQueryItem(name: "native_app_return_to", value: callback.url!.absoluteString)]
        var entry = URLComponents(url: authWebOrigin.appendingPathComponent("handler/native-sign-in"), resolvingAgainstBaseURL: false)!
        entry.queryItems = [URLQueryItem(name: "after_auth_return_to", value: after.url!.absoluteString)]
        return entry.url!
    }
}
