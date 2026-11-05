import CmuxNextCompat
public import Foundation

/// Native adapters for Rust's fetched NEXT Cloud client configuration.
/// ``from(selection:bundle:isDebugBuild:)`` is the app launch path. Backend
/// origins and Stack credentials always come from the Rust selection.
public struct CloudConfiguration: Sendable, Equatable {
    private static let unavailableBundleID = "com.cmuxterm.app.cloud-unavailable"

    /// Placeholder used only by test/capture composition roots that construct services before
    /// the async runtime bootstrap. A real NEXT app never reaches CloudService with this value.
    public static let unavailable = CloudConfiguration(
        backend: .localOnly(inertURL), apiBaseURL: inertURL, authWebOrigin: inertURL,
        stackBaseURL: inertURL, stackProjectID: "", stackPublishableClientKey: "",
        isProductionAuth: false, callbackScheme: "cmux", bundleID: unavailableBundleID, isDebugBuild: true)
    public enum Backend: Sendable, Equatable {
        /// A production selection returned by the backend.
        case production
        /// A non-production selection returned by the backend.
        case development(URL)
        /// A loopback origin selected for local development.
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
    /// The bundled CLI's selection for this launch; nil in legacy configuration fixtures.
    public var runtimeSelection: CloudRuntimeSelection?

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

    // This build's own token files, under `cmux/<bundle id>`: a namespace of
    // its own that predates ``BuildIdentity`` and is not that resolver's
    // `cmux/builds/<key>`. Routing it through the resolver would move every
    // existing build's token store and sign people out, so the literal root
    // stays here (its `move` row in scripts/cmux-next/state-roots-baseline.tsv),
    // and moving it is its own change with a migration.
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
        guard let selection = runtimeSelection else {
            return bundleID == Self.unavailableBundleID ? "bootstrap-unavailable" : nil
        }
        return selection.legacyStorage ? selection.authStorageNamespace : selection.authNamespace
    }

    static let signedDEVBundleID = "com.cmuxterm.app.debug.next"

    /// The account selected for a signed NEXT DEV launch. This is launch metadata only;
    /// backend origins and credentials still come from Rust's runtime selection.
    public enum DevAccount: String, Sendable, Equatable {
        case staging
        case nightly
    }

    /// A signed DEV production selection adopts the running NIGHTLY session in memory.
    public var adoptsNightlySession: Bool {
        !isDebugBuild && bundleID == Self.signedDEVBundleID && runtimeSelection?.name == "prod"
    }

    public static func launchAccount(chosen: DevAccount, nightlyIsRunning: () -> Bool) -> DevAccount {
        chosen == .nightly && !nightlyIsRunning() ? .staging : chosen
    }

    static let devAccountDefaultsKey = "cmux.next.dev.account"

    public static func devAccount(environment: [String: String], defaults: UserDefaults) -> DevAccount {
        let raw = environment["CMUX_NEXT_DEV_ACCOUNT"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let account = raw.flatMap(DevAccount.init(rawValue:)) {
            defaults.set(account.rawValue, forKey: devAccountDefaultsKey)
            return account
        }
        return defaults.string(forKey: devAccountDefaultsKey).flatMap(DevAccount.init(rawValue:)) ?? .staging
    }

    /// A signed NEXT DEV production launch may import the existing NIGHTLY session without
    /// changing or clearing NIGHTLY's own token store. This is read-only metadata for CloudAuth.
    public struct NightlySession: Sendable, Equatable {
        public var keychainService: String
        public var accessGroup: String
        public var credentialsDirectory: URL
    }

    public var nightlySession: NightlySession? {
        nightlySession(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Pure counterpart of ``nightlySession``, for configuration contract tests.
    func nightlySession(homeDirectory: URL) -> NightlySession? {
        guard runtimeSelection?.name == "prod", !isDebugBuild, bundleID == Self.signedDEVBundleID else { return nil }
        let nightly = BuildIdentity.nightlyBundleID
        // NIGHTLY's own Application Support root, from the resolver keyed on
        // NIGHTLY's identity (``BuildIdentity/appSupport(_:)``), never a literal
        // root (per-build isolation S7, cx-is1kf.8). NIGHTLY is the one build
        // that keeps the shared roots, so this stays the `cmux` directory while
        // this signed DEV build's own roots are elsewhere.
        let root = BuildIdentity(bundleID: nightly, bundledTag: nil)
            .appSupport(Self.applicationSupportDirectory(homeDirectory: homeDirectory))
        return NightlySession(
            keychainService: "\(nightly).auth",
            accessGroup: "7WLXT3NR37.\(nightly)",
            credentialsDirectory: root.appendingPathComponent(nightly, isDirectory: true))
    }

    /// `~/Library/Application Support/cmux`: the directory
    /// ``BuildIdentity/appSupport(_:)`` resolves a build's own state root under.
    static func applicationSupportDirectory(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
    }

    /// `<scheme>://auth-callback`. `/dev/null` stands in for a hand-built
    /// configuration with one that does not.
    public var callbackURL: URL { URL(string: "\(callbackScheme)://auth-callback") ?? Self.inertURL }

    /// Stands in where a literal URL failed to parse.
    static let inertURL = URL(fileURLWithPath: "/dev/null")

    /// Creates the NEXT configuration directly from Rust's validated client-config response.
    /// Bundle metadata controls only the native callback, never backend origins or Stack keys.
    public static func from(selection: CloudRuntimeSelection, bundle: Bundle = .main,
                            isDebugBuild: Bool) -> CloudConfiguration {
        from(selection: selection, bundleID: bundle.bundleIdentifier,
             bundled: bundle.object(forInfoDictionaryKey: "LSEnvironment") as? [String: String] ?? [:],
             process: ProcessInfo.processInfo.environment, isDebugBuild: isDebugBuild)
    }

    /// Pure counterpart for configuration contract tests.
    public static func from(selection: CloudRuntimeSelection, bundleID: String?,
                            bundled: [String: String], process: [String: String],
                            isDebugBuild: Bool) -> CloudConfiguration {
        let value = { (key: String) -> String? in
            let trimmed = (bundled[key] ?? process[key])?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        let identity = bundleID ?? selection.bundleId
        let tag = value("CMUX_TAG").flatMap(sanitizedSchemeTag)
        let scheme = value("CMUX_AUTH_CALLBACK_SCHEME").flatMap {
            URL(string: "\($0)://auth-callback") == nil ? nil : $0
        } ?? (identity == "com.cmuxterm.app.debug.next" ? "cmux-next-dev"
            : isDebugBuild ? (tag.map { "cmux-dev-\($0)" } ?? "cmux-dev") : defaultScheme(identity))
        return CloudConfiguration(
            backend: selection.name == "prod" ? .production : .development(selection.apiOrigin),
            apiBaseURL: selection.apiOrigin, authWebOrigin: selection.authWebOrigin,
            stackBaseURL: selection.stackOrigin, stackProjectID: selection.stackProjectId,
            stackPublishableClientKey: selection.stackClientKey, isProductionAuth: selection.name == "prod",
            callbackScheme: scheme, bundleID: identity, isDebugBuild: isDebugBuild,
            runtimeSelection: selection)
    }

    /// The selected backend's API origin. Rust has already validated and
    /// allowlisted this value before constructing the native configuration.
    public func ownerAPIBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        runtimeSelection?.apiOrigin ?? apiBaseURL
    }

    /// The selected backend's platform origin for relay-first chat. Runtime
    /// client configuration is authoritative; the API origin is the safe
    /// fallback for legacy fixtures without a runtime selection.
    public func relayAPIBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        runtimeSelection?.platformOrigin ?? apiBaseURL
    }

    /// The selected backend's share API origin. The daemon may name the room's
    /// origin directly; native code never infers it from build kind.
    public func shareAPIBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        runtimeSelection?.shareApiOrigin ?? apiBaseURL
    }

    /// Whether a guest link's owner token may come from `api`, the API the daemon's share room names.
    /// The backend selection is authoritative; native code never adds an origin by build kind.
    public func acceptsShareAPI(_ api: URL) -> Bool {
        api == (runtimeSelection?.shareApiOrigin ?? apiBaseURL)
    }

    /// Whether this compile has the bench hooks (`reload.sh --config bench`: `CMUX_BENCH_HOOKS`, never in a
    /// shipped app). With them, a `cap<sha10>` capture build's Cloud is configured as a Debug build's (``isCaptureBuild(bundleID:benchHooks:)``).
    public static var benchHooksCompiled: Bool {
        #if CMUX_BENCH_HOOKS
        true
        #else
        false
        #endif
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
