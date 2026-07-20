import CMUXAuthCore
import Foundation

enum AuthEnvironment {
    private static let developmentStackProjectID = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
    private static let developmentStackPublishableClientKey = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"
    private static let productionStackProjectID = "9790718f-14cd-4f7e-824d-eaf527a82b82"
    private static let productionStackPublishableClientKey = "pck_kzj80gx4mh2jrzn1cx6y5e8jk0kwa01vkevh2p9zd4twr"

    static var callbackScheme: String {
        callbackScheme(
            environment: ProcessInfo.processInfo.environment,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    static func callbackScheme(
        environment: [String: String],
        bundleIdentifier: String?
    ) -> String {
        #if DEBUG
        return callbackScheme(environment: environment, bundleIdentifier: bundleIdentifier, isDebugBuild: true)
        #else
        return callbackScheme(environment: environment, bundleIdentifier: bundleIdentifier, isDebugBuild: false)
        #endif
    }

    static func callbackScheme(
        environment: [String: String],
        bundleIdentifier: String?,
        isDebugBuild: Bool
    ) -> String {
        if let overridden = environment["CMUX_AUTH_CALLBACK_SCHEME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty {
            return overridden
        }
        if isDebugBuild {
            // Untagged Debug builds register cmux-dev:// so they can coexist
            // with the installed stable app. Tagged Debug builds use
            // cmux-dev-<tag>://.
            if let tag = environment["CMUX_TAG"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !tag.isEmpty,
               let schemeTag = sanitizedCallbackSchemeTag(tag) {
                return "cmux-dev-\(schemeTag)"
            }
            return "cmux-dev"
        }
        if bundleIdentifier == "com.cmuxterm.app.nightly" {
            return "cmux-nightly"
        }
        return "cmux"
    }

    static func sanitizedCallbackSchemeTag(_ rawTag: String) -> String? {
        let lowercased = rawTag.lowercased()
        var result = ""
        var previousWasHyphen = false
        for scalar in lowercased.unicodeScalars {
            let isAllowed = (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
            if isAllowed {
                result.unicodeScalars.append(scalar)
                previousWasHyphen = false
            } else if !previousWasHyphen {
                result.append("-")
                previousWasHyphen = true
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? nil : result
    }

    static var callbackURL: URL {
        URL(string: "\(callbackScheme)://auth-callback")!
    }

    static func resolvedCallbackURL(
        environment: [String: String],
        bundleIdentifier: String?
    ) -> URL {
        URL(string: "\(callbackScheme(environment: environment, bundleIdentifier: bundleIdentifier))://auth-callback")!
    }

    static var websiteOrigin: URL {
        resolvedURL(
            environmentKey: "CMUX_WWW_ORIGIN",
            fallback: "https://cmux.com"
        )
    }

    /// Pricing page used by every "Upgrade to cmux Pro" entrypoint
    /// (Settings, command palette, Help menu). Resolution order mirrors
    /// ``vmAPIBaseURL``: process env `CMUX_WWW_ORIGIN`, then the DEBUG-only
    /// `~/.cmux-dev.env` file (so a deeplink-launched dev build can point at
    /// a local web server), then the production website.
    static var pricingURL: URL {
        resolvedPricingURL(environment: ProcessInfo.processInfo.environment)
    }

    static func resolvedPricingURL(environment: [String: String]) -> URL {
        appWebOrigin(environment: environment).appendingPathComponent("pricing")
    }

    static var appPricingURL: URL {
        resolvedAppPricingURL(environment: ProcessInfo.processInfo.environment)
    }

    static var appWebOrigin: URL {
        resolvedAppWebOrigin(environment: ProcessInfo.processInfo.environment)
    }

    static func resolvedAppWebOrigin(environment: [String: String]) -> URL {
        appWebOrigin(environment: environment)
    }

    static func resolvedAppPricingURL(environment: [String: String]) -> URL {
        appWebOrigin(environment: environment).appendingPathComponent("app-pricing")
    }

    static var appProWelcomeURL: URL {
        resolvedAppProWelcomeURL(environment: ProcessInfo.processInfo.environment)
    }

    static func resolvedAppProWelcomeURL(environment: [String: String]) -> URL {
        appWebOrigin(environment: environment).appendingPathComponent("app-pro-welcome")
    }

    /// Payment entrypoint used by native app UI. `CMUX_BILLING_WWW_ORIGIN`
    /// can explicitly pin checkout elsewhere, otherwise checkout follows the
    /// same app web origin as `/app-pricing`. Direct Stripe Checkout binds the
    /// purchaser to the server-created session, so dev builds must start the
    /// request on the same origin that rendered pricing instead of crossing to
    /// production.
    static var billingCheckoutURL: URL {
        resolvedBillingCheckoutURL(environment: ProcessInfo.processInfo.environment)
    }

    static func resolvedBillingCheckoutURL(environment: [String: String]) -> URL {
        billingCheckoutURL(
            origin: billingWebsiteOrigin(environment: environment),
            callbackScheme: callbackScheme(environment: environment, bundleIdentifier: nil)
        )
    }

    static var billingPortalURL: URL {
        resolvedBillingPortalURL(environment: ProcessInfo.processInfo.environment)
    }

    static func resolvedBillingPortalURL(environment: [String: String]) -> URL {
        billingWebsiteOrigin(environment: environment).appendingPathComponent("api/billing/portal")
    }

    static var signInWebsiteOrigin: URL {
        canonicalizedLoopbackURL(
            resolvedURL(
                environmentKey: "CMUX_AUTH_WWW_ORIGIN",
                fallback: defaultWebOrigin
            )
        )
    }

    static var apiBaseURL: URL {
        canonicalizedLoopbackURL(
            resolvedURL(
                environmentKey: "CMUX_API_BASE_URL",
                fallback: defaultAPIBaseURL
            )
        )
    }

    /// Base URL for the cmux-owned cloud VM backend (`/api/vm`).
    ///
    /// Resolution order (first hit wins):
    ///   1. process env `CMUX_VM_API_BASE_URL` — works when the app is launched from a shell.
    ///   2. `~/.cmux-dev.env` file `CMUX_VM_API_BASE_URL=...` line — works regardless of how
    ///      the app was launched (click-through, Dock, `open`, etc.). Only honored in DEBUG.
    ///   3. VM backend dev origin (`http://localhost:$CMUX_PORT` in Debug, cmux.com in Release).
    static var vmAPIBaseURL: URL {
        if let overridden = ProcessInfo.processInfo.environment["CMUX_VM_API_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty,
           let url = URL(string: overridden) {
            return canonicalizedLoopbackURL(url)
        }
        if let override = devOverride(key: "CMUX_VM_API_BASE_URL"),
           let url = URL(string: override) {
            return canonicalizedLoopbackURL(url)
        }
        return canonicalizedLoopbackURL(URL(string: defaultVMAPIOrigin)!)
    }

    /// Authenticated route broker shared by matching tagged Mac and iOS builds.
    ///
    /// General tagged APIs remain on their isolated localhost origin. Iroh uses
    /// shared staging in Debug so separately launched processes publish into one
    /// account-scoped registry. Release keeps the production cmux origin.
    static var irohBrokerBaseURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        if let overridden = environment["CMUX_IROH_BROKER_BASE_URL"]?
           .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty {
            return validatedIrohBrokerURL(overridden)
        }
        #if DEBUG
        if let override = devOverride(key: "CMUX_IROH_BROKER_BASE_URL") {
            return validatedIrohBrokerURL(override)
        }
        return resolvedIrohBrokerBaseURL(environment: environment, isDebugBuild: true)
        #else
        return resolvedIrohBrokerBaseURL(environment: environment, isDebugBuild: false)
        #endif
    }

    static func resolvedIrohBrokerBaseURL(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> URL? {
        if let explicit = environment["CMUX_IROH_BROKER_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return validatedIrohBrokerURL(explicit)
        }
        let fallback = isDebugBuild
            ? "https://cmux-staging.vercel.app"
            : "https://cmux.com"
        return validatedIrohBrokerURL(fallback)
    }

    private static func validatedIrohBrokerURL(_ rawValue: String) -> URL? {
        guard let url = URL(string: rawValue),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        if scheme == "https" { return url }
        guard scheme == "http",
              ["127.0.0.1", "::1", "localhost"].contains(host) else {
            return nil
        }
        return canonicalizedLoopbackURL(url)
    }

    /// Look up `key=value` in `~/.cmux-dev.env` for the DEBUG build. Returns nil in Release.
    /// Kept tiny on purpose — this is a "drop a file, restart the app, it picks up" override,
    /// not a real config system.
    private static func devOverride(key: String) -> String? {
        #if DEBUG
        guard let home = ProcessInfo.processInfo.environment["HOME"] else { return nil }
        let path = (home as NSString).appendingPathComponent(".cmux-dev.env")
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for raw in data.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard k == key else { continue }
            var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
            if v.hasPrefix("'") && v.hasSuffix("'") { v = String(v.dropFirst().dropLast()) }
            return v.isEmpty ? nil : v
        }
        return nil
        #else
        return nil
        #endif
    }

    private static var cmuxPort: String {
        resolvedCmuxPort(environment: ProcessInfo.processInfo.environment)
    }

    private static func billingWebsiteOrigin(environment: [String: String]) -> URL {
        if let overridden = environmentURL("CMUX_BILLING_WWW_ORIGIN", environment: environment) {
            return overridden
        }
        return appWebOrigin(environment: environment)
    }

    private static func appWebOrigin(environment: [String: String]) -> URL {
        if let explicitWebsite = environmentURL("CMUX_WWW_ORIGIN", environment: environment) {
            return canonicalizedLoopbackURL(explicitWebsite)
        }
        if let authWebsite = environmentURL("CMUX_AUTH_WWW_ORIGIN", environment: environment) {
            return canonicalizedLoopbackURL(authWebsite)
        }
        #if DEBUG
        if environmentPort("CMUX_PORT", environment: environment) != nil ||
            environmentPort("PORT", environment: environment) != nil {
            return URL(string: resolvedDefaultWebOrigin(environment: environment))!
        }
        if let override = devOverride(key: "CMUX_WWW_ORIGIN"),
           let url = URL(string: override) {
            return canonicalizedLoopbackURL(url)
        }
        #endif
        return resolvedURL(
            environmentKey: "CMUX_WWW_ORIGIN",
            fallback: resolvedDefaultWebOrigin(environment: environment),
            environment: environment
        )
    }

    private static func billingCheckoutURL(origin: URL, callbackScheme: String) -> URL {
        var components = URLComponents(
            url: origin.appendingPathComponent("api/billing/checkout"),
            resolvingAgainstBaseURL: false
        )!
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "cmux_external_browser" }
        queryItems.removeAll { $0.name == "cmux_scheme" }
        queryItems.append(URLQueryItem(name: "cmux_external_browser", value: "1"))
        queryItems.append(URLQueryItem(name: "cmux_scheme", value: callbackScheme))
        components.queryItems = queryItems
        return components.url!
    }

    private static func resolvedCmuxPort(environment: [String: String]) -> String {
        environmentPort("CMUX_PORT", environment: environment)
            ?? environmentPort("PORT", environment: environment)
            ?? "3777"
    }

    private static func environmentPort(_ key: String) -> String? {
        environmentPort(key, environment: ProcessInfo.processInfo.environment)
    }

    private static func environmentPort(_ key: String, environment: [String: String]) -> String? {
        guard let port = environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let value = UInt16(port),
            value > 0
        else {
            return nil
        }
        return port
    }

    private static var defaultWebOrigin: String {
        resolvedDefaultWebOrigin(environment: ProcessInfo.processInfo.environment)
    }

    private static func resolvedDefaultWebOrigin(environment: [String: String]) -> String {
        if let origin = environment["CMUX_WWW_ORIGIN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !origin.isEmpty {
            return origin
        }
        #if DEBUG
        return "http://localhost:\(resolvedCmuxPort(environment: environment))"
        #else
        return "https://cmux.com"
        #endif
    }

    private static var defaultVMAPIOrigin: String {
        #if DEBUG
        return "http://localhost:\(cmuxPort)"
        #else
        return "https://cmux.com"
        #endif
    }

    private static var defaultAPIBaseURL: String {
        if let url = ProcessInfo.processInfo.environment["CMUX_API_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !url.isEmpty {
            return url
        }
        #if DEBUG
        return "http://localhost:\(cmuxPort)"
        #else
        return "https://api.cmux.sh"
        #endif
    }

    static var stackBaseURL: URL {
        resolvedURL(
            environmentKey: "CMUX_STACK_BASE_URL",
            fallback: "https://api.stack-auth.com"
        )
    }

    static var stackProjectID: String {
        #if DEBUG
        return resolvedStackProjectID(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: true
        )
        #else
        return resolvedStackProjectID(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: false
        )
        #endif
    }

    /// Resolve the Stack channel for a macOS build. Debug defaults to the
    /// development project, while `scripts/reload.sh --prod-auth` bakes an
    /// explicit production override into the tagged app's launch environment.
    /// Invalid values fail toward the build's normal channel.
    static func resolvedStackAuthEnvironment(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> CMUXAuthEnvironment {
        switch environment["CMUX_AUTH_ENVIRONMENT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "production":
            return .production
        case "development":
            return .development
        default:
            return isDebugBuild ? .development : .production
        }
    }

    static func resolvedStackProjectID(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> String {
        if let projectID = environment["CMUX_STACK_PROJECT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !projectID.isEmpty {
            return projectID
        }
        switch resolvedStackAuthEnvironment(
            environment: environment,
            isDebugBuild: isDebugBuild
        ) {
        case .development:
            return developmentStackProjectID
        case .production:
            return productionStackProjectID
        }
    }

    static var stackPublishableClientKey: String {
        #if DEBUG
        return resolvedStackPublishableClientKey(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: true
        )
        #else
        return resolvedStackPublishableClientKey(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: false
        )
        #endif
    }

    static func resolvedStackPublishableClientKey(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> String {
        if let clientKey = environment["CMUX_STACK_PUBLISHABLE_CLIENT_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !clientKey.isEmpty {
            return clientKey
        }
        switch resolvedStackAuthEnvironment(
            environment: environment,
            isDebugBuild: isDebugBuild
        ) {
        case .development:
            return developmentStackPublishableClientKey
        case .production:
            return productionStackPublishableClientKey
        }
    }

    /// The website origin used for the after-sign-in handler.
    static var afterSignInOrigin: URL {
        resolvedAfterSignInOrigin(environment: ProcessInfo.processInfo.environment)
    }

    static func resolvedAfterSignInOrigin(environment: [String: String]) -> URL {
        resolvedURL(
            environmentKey: "CMUX_AUTH_WWW_ORIGIN",
            fallback: resolvedDefaultWebOrigin(environment: environment),
            environment: environment
        )
    }

    static func signInURL(callbackState: String? = nil) -> URL {
        signInURL(callbackState: callbackState, afterSignInOrigin: afterSignInOrigin, callbackURL: callbackURL)
    }

    static func signInURL(
        callbackState: String? = nil,
        environment: [String: String],
        bundleIdentifier: String? = nil
    ) -> URL {
        signInURL(
            callbackState: callbackState,
            afterSignInOrigin: resolvedAfterSignInOrigin(environment: environment),
            callbackURL: resolvedCallbackURL(environment: environment, bundleIdentifier: bundleIdentifier)
        )
    }

    private static func signInURL(
        callbackState: String?,
        afterSignInOrigin: URL,
        callbackURL: URL
    ) -> URL {
        // Build the after-sign-in callback URL that includes the native app return scheme.
        // The after-sign-in handler extracts tokens from the Stack Auth session
        // and redirects to the native app via the cmux:// callback scheme.
        var afterSignInComponents = URLComponents(
            url: afterSignInOrigin.appendingPathComponent("handler/after-sign-in", isDirectory: false),
            resolvingAgainstBaseURL: false
        )!
        var nativeCallbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)!
        if let callbackState {
            nativeCallbackComponents.queryItems = [
                URLQueryItem(name: "cmux_auth_state", value: callbackState),
            ]
        }

        afterSignInComponents.queryItems = [
            URLQueryItem(
                name: "native_app_return_to",
                value: nativeCallbackComponents.url!.absoluteString
            ),
        ]

        // Enter through cmux's native sign-in wrapper, which sets a short-lived
        // server-side handoff nonce before redirecting to Stack's /sign-in.
        var components = URLComponents(
            url: afterSignInOrigin.appendingPathComponent("handler/native-sign-in", isDirectory: false),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(
                name: "after_auth_return_to",
                value: afterSignInComponents.url!.absoluteString
            ),
        ]
        return components.url!
    }

    private static func resolvedURL(environmentKey: String, fallback: String) -> URL {
        resolvedURL(
            environmentKey: environmentKey,
            fallback: fallback,
            environment: ProcessInfo.processInfo.environment
        )
    }

    private static func resolvedURL(
        environmentKey: String,
        fallback: String,
        environment: [String: String]
    ) -> URL {
        if let overridden = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty,
           let url = URL(string: overridden) {
            return url
        }
        return URL(string: fallback)!
    }

    private static func environmentURL(_ key: String, environment: [String: String]) -> URL? {
        guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        return URL(string: raw)
    }

    private static func canonicalizedLoopbackURL(_ url: URL) -> URL {
        guard let host = url.host?.lowercased() else {
            return url
        }

        let loopbackHosts = ["127.0.0.1", "::1", "[::1]", "0.0.0.0"]
        guard loopbackHosts.contains(host) else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = "localhost"
        return components?.url ?? url
    }
}
