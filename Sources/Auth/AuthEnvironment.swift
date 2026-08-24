import CMUXAuthCore
import Foundation

enum AuthEnvironment {
    private static let developmentStackProjectID = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
    private static let developmentStackPublishableClientKey = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"
    private static let productionStackProjectID = "9790718f-14cd-4f7e-824d-eaf527a82b82"
    private static let productionStackPublishableClientKey = "pck_kzj80gx4mh2jrzn1cx6y5e8jk0kwa01vkevh2p9zd4twr"

    /// The persisted EXPLICIT backend environment choice (Settings > Account
    /// > Backend Environment), or nil when no choice is persisted and the
    /// build runs its own lane. An explicit choice is a WHOLESALE override:
    /// every backend `resolved*` function below consults it as its FIRST
    /// tier — ABOVE explicit `CMUX_*` environment variables (including the
    /// LSEnvironment values tagged dev builds bake in via
    /// `scripts/reload.sh`), the DEBUG-only `~/.cmux-dev.env` file, and
    /// `#if DEBUG` compile defaults — replacing the entire backend key set
    /// atomically, so a switched build can never run half on one environment
    /// and half on another. With NO choice (absent key) every resolution is
    /// byte-identical to the pre-choice behavior, keeping the bake as the
    /// dev-lane isolation mechanism. `callbackScheme` deliberately stays
    /// outside the wholesale set: tagged deep-link routing must survive a
    /// switch.
    ///
    /// Loaded fresh at each ProcessInfo-reading resolution site. The
    /// composition root still resolves once at startup; the live switch
    /// transaction rebuilds that frozen graph when the choice changes.
    static var backendEnvironmentExplicitChoice: CMUXBackendEnvironmentOverride? {
        CMUXBackendEnvironmentOverride.explicitChoice(from: .standard)
    }

    /// The full fixed backend value set an explicit environment choice
    /// selects, wholesale. One helper so a choice can never mix tiers:
    /// either every value below comes from this table, or none does.
    private struct ExplicitBackendValues {
        let webOrigin: String
        /// Explicit production uses api.cmux.sh for Release-lane parity
        /// (the unpinned Release default); staging's Next.js app serves the
        /// same `/api/*` routes itself.
        let apiBaseURL: String
        let vmAPIOrigin: String
        /// The push relay follows the VM-API origin under a choice.
        let pushAPIOrigin: String
        let irohBrokerOrigin: String
        let stackAuthEnvironment: CMUXAuthEnvironment
        let stackProjectID: String
        let stackPublishableClientKey: String
        /// Credential-bearing handoffs stay pinned to the two compiled-in
        /// origins; an explicit choice picks one, never a computed value.
        let sessionHandoffOrigin: String

        static func values(
            for choice: CMUXBackendEnvironmentOverride
        ) -> ExplicitBackendValues {
            switch choice {
            case .production:
                ExplicitBackendValues(
                    webOrigin: "https://cmux.com",
                    apiBaseURL: "https://api.cmux.sh",
                    vmAPIOrigin: "https://cmux.com",
                    pushAPIOrigin: "https://cmux.com",
                    irohBrokerOrigin: "https://cmux.com",
                    stackAuthEnvironment: .production,
                    stackProjectID: productionStackProjectID,
                    stackPublishableClientKey: productionStackPublishableClientKey,
                    sessionHandoffOrigin: "https://cmux.com"
                )
            case .staging:
                ExplicitBackendValues(
                    webOrigin: CMUXBackendEnvironmentOverride.stagingWebOrigin,
                    apiBaseURL: CMUXBackendEnvironmentOverride.stagingWebOrigin,
                    vmAPIOrigin: CMUXBackendEnvironmentOverride.stagingWebOrigin,
                    pushAPIOrigin: CMUXBackendEnvironmentOverride.stagingWebOrigin,
                    irohBrokerOrigin: CMUXBackendEnvironmentOverride.stagingWebOrigin,
                    stackAuthEnvironment: .development,
                    stackProjectID: developmentStackProjectID,
                    stackPublishableClientKey: developmentStackPublishableClientKey,
                    sessionHandoffOrigin: CMUXBackendEnvironmentOverride.stagingWebOrigin
                )
            }
        }
    }

    /// Classify this build's LANE: the backend the process resolves with NO
    /// explicit choice, from the launch environment and build flags alone.
    /// Powers the Settings picker's "Build lane (…)" option and the
    /// return-to-lane sign-out chain; an unpinned Release build is the
    /// production lane, a staging-baked build the staging lane, and every
    /// other bake (tagged dev builds on a localhost origin, untagged Debug
    /// builds on the development Stack channel) a custom lane labeled with
    /// its lane web origin.
    static func resolvedBackendEnvironmentBuildLane(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> CMUXBackendEnvironmentBuildLane {
        let laneWebOrigin = resolvedWebsiteOrigin(
            environment: environment,
            isDebugBuild: isDebugBuild,
            explicitChoice: nil
        )
        let laneStackEnvironment = resolvedStackAuthEnvironment(
            environment: environment,
            isDebugBuild: isDebugBuild,
            explicitChoice: nil
        )
        if laneWebOrigin.absoluteString == CMUXBackendEnvironmentOverride.stagingWebOrigin {
            return .staging
        }
        if laneStackEnvironment == .production,
           laneWebOrigin.absoluteString == "https://cmux.com" {
            return .production
        }
        return .custom(label: buildLaneLabel(for: laneWebOrigin))
    }

    /// Human label for a custom lane: host, or host:port.
    private static func buildLaneLabel(for origin: URL) -> String {
        guard let host = origin.host else { return origin.absoluteString }
        guard let port = origin.port else { return host }
        return "\(host):\(port)"
    }

    /// Whether this binary was compiled as a Debug build. The pure
    /// `resolved*` functions take this as a parameter so tests can exercise
    /// Release resolution; ProcessInfo-reading computed vars pass this value.
    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

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
        resolvedWebsiteOrigin(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: isDebugBuild,
            explicitChoice: backendEnvironmentExplicitChoice
        )
    }

    static func resolvedWebsiteOrigin(
        environment: [String: String],
        isDebugBuild: Bool,
        explicitChoice: CMUXBackendEnvironmentOverride? = nil
    ) -> URL {
        // Wholesale head: an explicit choice's fixed web origin beats env
        // (baked LSEnvironment included). No choice keeps the fixed cmux.com
        // fallback below env, byte-identical to the pre-choice behavior.
        if let explicitChoice {
            return URL(string: ExplicitBackendValues.values(for: explicitChoice).webOrigin)!
        }
        return resolvedURL(
            environmentKey: "CMUX_WWW_ORIGIN",
            fallback: "https://cmux.com",
            environment: environment
        )
    }

    /// Pricing page used by every "Upgrade to cmux Pro" entrypoint
    /// (Settings, command palette, Help menu). Resolution order mirrors
    /// ``vmAPIBaseURL``: process env `CMUX_WWW_ORIGIN`, then the DEBUG-only
    /// `~/.cmux-dev.env` file (so a deeplink-launched dev build can point at
    /// a local web server), then the production website.
    static var pricingURL: URL {
        resolvedPricingURL(
            environment: ProcessInfo.processInfo.environment,
            explicitChoice: backendEnvironmentExplicitChoice
        )
    }

    /// Delegators like this one carry no head of their own: the wholesale
    /// head lives in ``appWebOrigin(environment:isDebugBuild:explicitChoice:)``,
    /// which every pricing/billing URL below derives from.
    static func resolvedPricingURL(
        environment: [String: String],
        explicitChoice: CMUXBackendEnvironmentOverride? = nil
    ) -> URL {
        appWebOrigin(
            environment: environment,
            isDebugBuild: isDebugBuild,
            explicitChoice: explicitChoice
        )
        .appendingPathComponent("pricing")
    }

    static var appPricingURL: URL {
        resolvedAppPricingURL(
            environment: ProcessInfo.processInfo.environment,
            explicitChoice: backendEnvironmentExplicitChoice
        )
    }

    static var appWebOrigin: URL {
        resolvedAppWebOrigin(
            environment: ProcessInfo.processInfo.environment,
            explicitChoice: backendEnvironmentExplicitChoice
        )
    }

    /// Credential-bearing native-to-web handoffs are pinned to cmux.com in
    /// release builds. An explicit backend choice hands off to exactly its
    /// fixed compiled-in origin (cmux.com, or
    /// ``CMUXBackendEnvironmentOverride/stagingWebOrigin``); the destination
    /// set never widens beyond those two fixed origins. Debug builds may
    /// additionally use an exact loopback origin so tagged local web servers
    /// can participate without making an arbitrary launch environment
    /// variable a token destination.
    static var appSessionHandoffOrigin: URL {
        resolvedAppSessionHandoffOrigin(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: isDebugBuild,
            explicitChoice: backendEnvironmentExplicitChoice
        )
    }

    static func resolvedAppSessionHandoffOrigin(
        environment: [String: String],
        isDebugBuild: Bool,
        explicitChoice: CMUXBackendEnvironmentOverride? = nil
    ) -> URL {
        // Wholesale head: an explicit choice hands off to exactly its fixed
        // compiled-in origin — never a computed or env-derived value, so an
        // env-injected lookalike can never become a token destination.
        if let explicitChoice {
            return URL(
                string: ExplicitBackendValues.values(for: explicitChoice).sessionHandoffOrigin
            )!
        }
        let productionOrigin = URL(string: "https://cmux.com")!
        let candidate = canonicalizedLoopbackURL(
            appWebOrigin(
                environment: environment,
                isDebugBuild: isDebugBuild,
                explicitChoice: nil
            )
        )
        if candidate == productionOrigin { return productionOrigin }
        guard isDebugBuild else { return productionOrigin }
        guard let components = URLComponents(
            url: candidate,
            resolvingAgainstBaseURL: false
        ),
              components.scheme == "http" || components.scheme == "https",
              components.host?.lowercased() == "localhost",
              components.user == nil,
              components.password == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil else {
            return productionOrigin
        }
        return candidate
    }

    static func resolvedAppWebOrigin(
        environment: [String: String],
        explicitChoice: CMUXBackendEnvironmentOverride? = nil
    ) -> URL {
        appWebOrigin(
            environment: environment,
            isDebugBuild: isDebugBuild,
            explicitChoice: explicitChoice
        )
    }

    static func resolvedAppPricingURL(
        environment: [String: String],
        explicitChoice: CMUXBackendEnvironmentOverride? = nil
    ) -> URL {
        appWebOrigin(
            environment: environment,
            isDebugBuild: isDebugBuild,
            explicitChoice: explicitChoice
        )
        .appendingPathComponent("app-pricing")
    }

    static var appProWelcomeURL: URL {
        resolvedAppProWelcomeURL(
            environment: ProcessInfo.processInfo.environment,
            explicitChoice: backendEnvironmentExplicitChoice
        )
    }

    static func resolvedAppProWelcomeURL(
        environment: [String: String],
        explicitChoice: CMUXBackendEnvironmentOverride? = nil
    ) -> URL {
        appWebOrigin(
            environment: environment,
            isDebugBuild: isDebugBuild,
            explicitChoice: explicitChoice
        )
        .appendingPathComponent("app-pro-welcome")
    }

    /// Payment entrypoint used by native app UI. `CMUX_BILLING_WWW_ORIGIN`
    /// can explicitly pin checkout elsewhere, otherwise checkout follows the
    /// same app web origin as `/app-pricing`. Direct Stripe Checkout binds the
    /// purchaser to the server-created session, so dev builds must start the
    /// request on the same origin that rendered pricing instead of crossing to
    /// production.
    static var billingCheckoutURL: URL {
        resolvedBillingCheckoutURL(
            environment: ProcessInfo.processInfo.environment,
            explicitChoice: backendEnvironmentExplicitChoice
        )
    }

    static func resolvedBillingCheckoutURL(
        environment: [String: String],
        explicitChoice: CMUXBackendEnvironmentOverride? = nil
    ) -> URL {
        billingCheckoutURL(
            origin: billingWebsiteOrigin(
                environment: environment,
                explicitChoice: explicitChoice
            ),
            callbackScheme: callbackScheme(environment: environment, bundleIdentifier: nil)
        )
    }

    static var billingPortalURL: URL {
        resolvedBillingPortalURL(
            environment: ProcessInfo.processInfo.environment,
            explicitChoice: backendEnvironmentExplicitChoice
        )
    }

    static func resolvedBillingPortalURL(
        environment: [String: String],
        explicitChoice: CMUXBackendEnvironmentOverride? = nil
    ) -> URL {
        billingWebsiteOrigin(environment: environment, explicitChoice: explicitChoice)
            .appendingPathComponent("api/billing/portal")
    }

    static var apiBaseURL: URL {
        // Wholesale head: an explicit choice's fixed API base beats
        // `CMUX_API_BASE_URL` (baked LSEnvironment included).
        if let choice = backendEnvironmentExplicitChoice {
            return canonicalizedLoopbackURL(
                URL(string: ExplicitBackendValues.values(for: choice).apiBaseURL)!
            )
        }
        return canonicalizedLoopbackURL(
            resolvedURL(
                environmentKey: "CMUX_API_BASE_URL",
                fallback: defaultAPIBaseURL
            )
        )
    }

    /// API base resolution. An explicit choice is a wholesale head: explicit
    /// production is api.cmux.sh (Release-lane parity; it only fronts calls
    /// like `/api/billing/plan`), explicit staging is the staging web
    /// origin, whose Next.js app serves the same `/api/*` routes itself.
    /// With no choice, `CMUX_API_BASE_URL` wins, Debug keeps the tag-local
    /// dev port, and Release stays on api.cmux.sh.
    static func resolvedDefaultAPIBaseURL(
        environment: [String: String],
        isDebugBuild: Bool,
        explicitChoice: CMUXBackendEnvironmentOverride? = nil
    ) -> String {
        if let explicitChoice {
            return ExplicitBackendValues.values(for: explicitChoice).apiBaseURL
        }
        if let url = environment["CMUX_API_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !url.isEmpty {
            return url
        }
        if isDebugBuild {
            return "http://localhost:\(resolvedCmuxPort(environment: environment))"
        }
        return "https://api.cmux.sh"
    }

    /// Base URL for the cmux-owned cloud VM backend (`/api/vm`).
    ///
    /// Resolution order (first hit wins):
    ///   0. the persisted explicit backend choice — a wholesale override
    ///      beating every tier below.
    ///   1. process env `CMUX_VM_API_BASE_URL` — works when the app is launched from a shell.
    ///   2. `~/.cmux-dev.env` file `CMUX_VM_API_BASE_URL=...` line — works regardless of how
    ///      the app was launched (click-through, Dock, `open`, etc.). Only honored in DEBUG.
    ///   3. VM backend dev origin (`http://localhost:$CMUX_PORT` in Debug, cmux.com in Release).
    static var vmAPIBaseURL: URL {
        if let choice = backendEnvironmentExplicitChoice {
            return canonicalizedLoopbackURL(
                URL(string: ExplicitBackendValues.values(for: choice).vmAPIOrigin)!
            )
        }
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

    /// Base URL for the phone-push relay (`/api/notifications/*`).
    ///
    /// Dev iPhones register their APNs tokens with the shared staging
    /// deployment (the device rig's default origin), so a Debug Mac must post
    /// pushes there too — a tag-local localhost port has no token registry and
    /// every forward would die queued. The tag rig BAKES a localhost
    /// `CMUX_VM_API_BASE_URL` into every Debug bundle, so that knob must not
    /// steer the push lane; a deliberately local push rig sets
    /// `CMUX_PUSH_API_BASE_URL` (env or `~/.cmux-dev.env`) instead. An
    /// explicit backend choice is a wholesale head following its VM-API
    /// origin; with no choice, Debug defaults to shared staging (mirroring
    /// `irohBrokerBaseURL`) and Release keeps the production VM-API origin.
    static var pushAPIBaseURL: URL {
        if let choice = backendEnvironmentExplicitChoice {
            return canonicalizedLoopbackURL(
                URL(string: ExplicitBackendValues.values(for: choice).pushAPIOrigin)!
            )
        }
        let environment = ProcessInfo.processInfo.environment
        if let overridden = environment["CMUX_PUSH_API_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty,
           let url = URL(string: overridden) {
            return canonicalizedLoopbackURL(url)
        }
        #if DEBUG
        if let override = devOverride(key: "CMUX_PUSH_API_BASE_URL"),
           let url = URL(string: override) {
            return canonicalizedLoopbackURL(url)
        }
        return URL(string: "https://cmux-staging.vercel.app")!
        #else
        return vmAPIBaseURL
        #endif
    }

    /// Pure mirror of ``pushAPIBaseURL`` for tests (the computed var adds
    /// only the DEBUG-only `~/.cmux-dev.env` tier, which reads a file and so
    /// stays out of the pure resolution).
    static func resolvedPushAPIBaseURL(
        environment: [String: String],
        isDebugBuild: Bool,
        explicitChoice: CMUXBackendEnvironmentOverride? = nil
    ) -> URL {
        if let explicitChoice {
            return canonicalizedLoopbackURL(
                URL(string: ExplicitBackendValues.values(for: explicitChoice).pushAPIOrigin)!
            )
        }
        if let overridden = environment["CMUX_PUSH_API_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty,
           let url = URL(string: overridden) {
            return canonicalizedLoopbackURL(url)
        }
        if isDebugBuild {
            return URL(string: CMUXBackendEnvironmentOverride.stagingWebOrigin)!
        }
        // The Release lane follows the VM-API origin: explicit env first,
        // then the build default.
        if let overridden = environment["CMUX_VM_API_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty,
           let url = URL(string: overridden) {
            return canonicalizedLoopbackURL(url)
        }
        return canonicalizedLoopbackURL(
            URL(string: resolvedDefaultVMAPIOrigin(
                environment: environment,
                isDebugBuild: isDebugBuild
            ))!
        )
    }

    /// Authenticated route broker shared by matching tagged Mac and iOS builds.
    ///
    /// General tagged APIs remain on their isolated localhost origin. Iroh uses
    /// shared staging in Debug so separately launched processes publish into one
    /// account-scoped registry. Release keeps the production cmux origin. An
    /// explicit backend choice is a wholesale head over all of it.
    static var irohBrokerBaseURL: URL? {
        if let choice = backendEnvironmentExplicitChoice {
            return validatedIrohBrokerURL(
                ExplicitBackendValues.values(for: choice).irohBrokerOrigin
            )
        }
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
        return resolvedIrohBrokerBaseURL(
            environment: environment,
            isDebugBuild: true
        )
        #else
        return resolvedIrohBrokerBaseURL(
            environment: environment,
            isDebugBuild: false
        )
        #endif
    }

    static func resolvedIrohBrokerBaseURL(
        environment: [String: String],
        isDebugBuild: Bool,
        explicitChoice: CMUXBackendEnvironmentOverride? = nil
    ) -> URL? {
        // Wholesale head: an explicit choice brokers through its own fixed
        // origin — a staging Mac and phone publish into one account-scoped
        // registry, an explicit-production pick leaves the shared Debug
        // staging registry.
        if let explicitChoice {
            return validatedIrohBrokerURL(
                ExplicitBackendValues.values(for: explicitChoice).irohBrokerOrigin
            )
        }
        if let explicit = environment["CMUX_IROH_BROKER_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return validatedIrohBrokerURL(explicit)
        }
        let fallback = isDebugBuild
            ? CMUXBackendEnvironmentOverride.stagingWebOrigin
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

    private static func billingWebsiteOrigin(
        environment: [String: String],
        explicitChoice: CMUXBackendEnvironmentOverride?
    ) -> URL {
        // Wholesale head: an explicit choice pins checkout to its fixed web
        // origin, above even the dedicated CMUX_BILLING_WWW_ORIGIN knob —
        // billing must never cross environments.
        if let explicitChoice {
            return URL(string: ExplicitBackendValues.values(for: explicitChoice).webOrigin)!
        }
        if let overridden = environmentURL("CMUX_BILLING_WWW_ORIGIN", environment: environment) {
            return overridden
        }
        return appWebOrigin(
            environment: environment,
            isDebugBuild: isDebugBuild,
            explicitChoice: nil
        )
    }

    private static func appWebOrigin(
        environment: [String: String],
        isDebugBuild: Bool,
        explicitChoice: CMUXBackendEnvironmentOverride?
    ) -> URL {
        // Wholesale head over both origin env vars and the Debug port bake.
        if let explicitChoice {
            return URL(string: ExplicitBackendValues.values(for: explicitChoice).webOrigin)!
        }
        if let explicitWebsite = environmentURL("CMUX_WWW_ORIGIN", environment: environment) {
            return canonicalizedLoopbackURL(explicitWebsite)
        }
        if let authWebsite = environmentURL("CMUX_AUTH_WWW_ORIGIN", environment: environment) {
            return canonicalizedLoopbackURL(authWebsite)
        }
        if isDebugBuild {
            if environmentPort("CMUX_PORT", environment: environment) != nil ||
                environmentPort("PORT", environment: environment) != nil {
                return URL(string: resolvedDefaultWebOrigin(
                    environment: environment,
                    isDebugBuild: isDebugBuild
                ))!
            }
            // `devOverride` is itself compiled out of Release builds, so this
            // runtime branch changes nothing for real builds while keeping
            // Release resolution testable from the Debug-built test target.
            if let devValue = devOverride(key: "CMUX_WWW_ORIGIN"),
               let url = URL(string: devValue) {
                return canonicalizedLoopbackURL(url)
            }
        }
        return resolvedURL(
            environmentKey: "CMUX_WWW_ORIGIN",
            fallback: resolvedDefaultWebOrigin(
                environment: environment,
                isDebugBuild: isDebugBuild
            ),
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
        resolvedDefaultWebOrigin(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: isDebugBuild,
            explicitChoice: backendEnvironmentExplicitChoice
        )
    }

    /// Build-default web origin. An explicit choice is a wholesale head
    /// (fixed cmux.com or staging origin, above even `CMUX_WWW_ORIGIN`).
    /// With no choice: env wins, Debug defaults to the tag-local dev port,
    /// Release to cmux.com.
    static func resolvedDefaultWebOrigin(
        environment: [String: String],
        isDebugBuild: Bool,
        explicitChoice: CMUXBackendEnvironmentOverride? = nil
    ) -> String {
        if let explicitChoice {
            return ExplicitBackendValues.values(for: explicitChoice).webOrigin
        }
        if let origin = environment["CMUX_WWW_ORIGIN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !origin.isEmpty {
            return origin
        }
        if isDebugBuild {
            return "http://localhost:\(resolvedCmuxPort(environment: environment))"
        }
        return "https://cmux.com"
    }

    private static var defaultVMAPIOrigin: String {
        resolvedDefaultVMAPIOrigin(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: isDebugBuild,
            explicitChoice: backendEnvironmentExplicitChoice
        )
    }

    /// Build-default VM API origin. An explicit choice is a wholesale head;
    /// with no choice, Debug keeps the tag-local dev port and Release is
    /// cmux.com. Explicit `CMUX_VM_API_BASE_URL` layers are checked by
    /// ``vmAPIBaseURL`` before this default is consulted (and after its
    /// choice head).
    static func resolvedDefaultVMAPIOrigin(
        environment: [String: String],
        isDebugBuild: Bool,
        explicitChoice: CMUXBackendEnvironmentOverride? = nil
    ) -> String {
        if let explicitChoice {
            return ExplicitBackendValues.values(for: explicitChoice).vmAPIOrigin
        }
        if isDebugBuild {
            return "http://localhost:\(resolvedCmuxPort(environment: environment))"
        }
        return "https://cmux.com"
    }

    private static var defaultAPIBaseURL: String {
        resolvedDefaultAPIBaseURL(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: isDebugBuild,
            explicitChoice: backendEnvironmentExplicitChoice
        )
    }

    static var stackBaseURL: URL {
        resolvedURL(
            environmentKey: "CMUX_STACK_BASE_URL",
            fallback: "https://api.stack-auth.com"
        )
    }

    static var stackProjectID: String {
        resolvedStackProjectID(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: isDebugBuild,
            explicitChoice: backendEnvironmentExplicitChoice
        )
    }

    /// Resolve the Stack channel for a macOS build. An explicit backend
    /// choice is a wholesale head — even the DEBUG development default
    /// yields to it, so an explicit production pick on a Debug build talks
    /// to the production Stack project (and dev auto-login, which keys on
    /// the resolved channel, disables itself for free). With no choice,
    /// `CMUX_AUTH_ENVIRONMENT` wins (`scripts/reload.sh --prod-auth` bakes
    /// it into the tagged app's launch environment), invalid values fail
    /// toward the build's normal channel, Debug defaults to development,
    /// and Release to production.
    static func resolvedStackAuthEnvironment(
        environment: [String: String],
        isDebugBuild: Bool,
        explicitChoice: CMUXBackendEnvironmentOverride? = nil
    ) -> CMUXAuthEnvironment {
        if let explicitChoice {
            return ExplicitBackendValues.values(for: explicitChoice).stackAuthEnvironment
        }
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
        isDebugBuild: Bool,
        explicitChoice: CMUXBackendEnvironmentOverride? = nil
    ) -> String {
        // Wholesale head: above CMUX_STACK_PROJECT_ID too, so a choice can
        // never pair one project's id with another environment's key.
        if let explicitChoice {
            return ExplicitBackendValues.values(for: explicitChoice).stackProjectID
        }
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
        resolvedStackPublishableClientKey(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: isDebugBuild,
            explicitChoice: backendEnvironmentExplicitChoice
        )
    }

    static func resolvedStackPublishableClientKey(
        environment: [String: String],
        isDebugBuild: Bool,
        explicitChoice: CMUXBackendEnvironmentOverride? = nil
    ) -> String {
        if let explicitChoice {
            return ExplicitBackendValues.values(for: explicitChoice).stackPublishableClientKey
        }
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
        resolvedAfterSignInOrigin(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: isDebugBuild,
            explicitChoice: backendEnvironmentExplicitChoice
        )
    }

    static func resolvedAfterSignInOrigin(
        environment: [String: String],
        isDebugBuild: Bool = AuthEnvironment.isDebugBuild,
        explicitChoice: CMUXBackendEnvironmentOverride? = nil
    ) -> URL {
        // Wholesale head: sign-in must enter the chosen environment's own
        // handler pages, above the CMUX_AUTH_WWW_ORIGIN bake.
        if let explicitChoice {
            return URL(string: ExplicitBackendValues.values(for: explicitChoice).webOrigin)!
        }
        return resolvedURL(
            environmentKey: "CMUX_AUTH_WWW_ORIGIN",
            fallback: resolvedDefaultWebOrigin(
                environment: environment,
                isDebugBuild: isDebugBuild
            ),
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
