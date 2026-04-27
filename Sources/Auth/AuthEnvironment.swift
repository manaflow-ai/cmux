import Foundation

enum AuthEnvironment {
    private static let developmentStackProjectID = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
    private static let developmentStackPublishableClientKey = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"
    private static let productionStackProjectID = "9790718f-14cd-4f7e-824d-eaf527a82b82"
    private static let productionStackPublishableClientKey = "pck_kzj80gx4mh2jrzn1cx6y5e8jk0kwa01vkevh2p9zd4twr"

    static var callbackScheme: String {
        let environment = ProcessInfo.processInfo.environment
        if let overridden = environment["CMUX_AUTH_CALLBACK_SCHEME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty {
            return overridden
        }
        // Match the Info.plist CFBundleURLSchemes $(CMUX_AUTH_CALLBACK_SCHEME)
        // expansion: cmux-dev in Debug builds, cmux in Release. Without this
        // Debug split, beginSignIn() would start an ASWebAuthenticationSession
        // listening on "cmux" while the OS routes cmux-dev:// → this app.
        #if DEBUG
        return "cmux-dev"
        #else
        return "cmux"
        #endif
    }

    static var callbackURL: URL {
        URL(string: "\(callbackScheme)://auth-callback")!
    }

    static var websiteOrigin: URL {
        resolvedURL(
            environmentKey: "CMUX_WWW_ORIGIN",
            fallback: "https://cmux.com"
        )
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
        environmentPort("CMUX_PORT") ?? environmentPort("PORT") ?? "3777"
    }

    private static func environmentPort(_ key: String) -> String? {
        guard let port = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let value = UInt16(port),
            value > 0
        else {
            return nil
        }
        return port
    }

    private static var defaultWebOrigin: String {
        if let origin = ProcessInfo.processInfo.environment["CMUX_WWW_ORIGIN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !origin.isEmpty {
            return origin
        }
        #if DEBUG
        return "http://localhost:\(cmuxPort)"
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
        let environment = ProcessInfo.processInfo.environment
        if let projectID = environment["CMUX_STACK_PROJECT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !projectID.isEmpty {
            return projectID
        }
        #if DEBUG
        return developmentStackProjectID
        #else
        return productionStackProjectID
        #endif
    }

    static var stackPublishableClientKey: String {
        let environment = ProcessInfo.processInfo.environment
        if let clientKey = environment["CMUX_STACK_PUBLISHABLE_CLIENT_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !clientKey.isEmpty {
            return clientKey
        }
        #if DEBUG
        return developmentStackPublishableClientKey
        #else
        return productionStackPublishableClientKey
        #endif
    }

    /// The website origin used for the after-sign-in handler.
    static var afterSignInOrigin: URL {
        resolvedURL(
            environmentKey: "CMUX_AUTH_WWW_ORIGIN",
            fallback: defaultWebOrigin
        )
    }

    static func signInURL() -> URL {
        // Build the after-sign-in callback URL that includes the native app return scheme.
        // The after-sign-in handler extracts tokens from the Stack Auth session
        // and redirects to the native app via the cmux:// callback scheme.
        var afterSignInComponents = URLComponents(
            url: afterSignInOrigin.appendingPathComponent("handler/after-sign-in", isDirectory: false),
            resolvingAgainstBaseURL: false
        )!
        afterSignInComponents.queryItems = [
            URLQueryItem(
                name: "native_app_return_to",
                value: callbackURL.absoluteString
            ),
        ]

        // Use the website's /sign-in route (provided by Stack Auth SDK).
        // Stack Auth handles the sign-in flow, then redirects to after_auth_return_to.
        var components = URLComponents(
            url: afterSignInOrigin.appendingPathComponent("handler/sign-in", isDirectory: false),
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
        let environment = ProcessInfo.processInfo.environment
        if let overridden = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty,
           let url = URL(string: overridden) {
            return url
        }
        return URL(string: fallback)!
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
