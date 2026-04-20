import Foundation

enum AuthEnvironment {
    private static let developmentStackProjectID = "1467bed0-8522-45ee-a8d8-055de324118c"
    private static let developmentStackPublishableClientKey = "pck_pt4nwry6sdskews2pxk4g2fbe861ak2zvaf3mqendspa0"
    private static let productionStackProjectID = "8a877114-b905-47c5-8b64-3a2d90679577"
    private static let productionStackPublishableClientKey = "pck_pqghntgd942k1hg066m7htjakb8g4ybaj66hqj2g2frj0"

    static var callbackScheme: String {
        let environment = ProcessInfo.processInfo.environment
        if let overridden = environment["CMUX_AUTH_CALLBACK_SCHEME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty {
            return overridden
        }
        return "manaflow"
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

    private static var cmuxPort: String {
        ProcessInfo.processInfo.environment["CMUX_PORT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "3000"
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
        // and redirects to the native app via the manaflow:// callback scheme.
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
