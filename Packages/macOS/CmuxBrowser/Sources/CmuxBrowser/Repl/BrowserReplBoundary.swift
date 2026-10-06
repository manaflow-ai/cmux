import Foundation

/// The native side of a REPL session's guards: secret values, the domain
/// policy and output redaction.
///
/// Agent code runs in the same JavaScript context as the runtime, so nothing
/// the runtime does in JavaScript can be a boundary: agent code can replace
/// any runtime object. These guards therefore live here, between that context
/// and the driver. Every driver call, fetch, event, file write and output line
/// passes through the session, which applies them whatever the JavaScript
/// side did.
final class BrowserReplBoundary: @unchecked Sendable {
    let secrets: BrowserReplSecretStore
    private let lock = NSLock()
    private var policy = BrowserReplDomainPolicy()
    private let publicSuffixes: BrowserReplPublicSuffixList
    /// Read only by the egress gate (``egress(_:)``).
    let typedSecrets: @Sendable () -> BrowserReplSecretStore?
    /// Whether masking bytes on the session's JavaScript thread is to stop
    /// (the cell timed out, a late callback ran past its limit, the session
    /// closed); read by the egress gate between chunks of a long scan.
    let isCancelled: @Sendable () -> Bool
    /// The session's working and temporary directories, the only places a
    /// navigation may load a file from.
    private var fileRoots: [String] = []
    /// The domains of each secret the session sent to be typed, and of each
    /// sign-in sheet it asked for: the policy may not let pages reach past
    /// any of them from then on (``secretTypingRefusal(name:domains:)``,
    /// ``credentialDomains(origin:)``).
    private var typedSecretDomains: [[BrowserReplDomainPattern]] = []

    /// - Parameters:
    ///   - publicSuffixes: The list `site` and `publicSuffix` answers come
    ///     from, and that refuses wildcard patterns over a public suffix.
    ///   - typedSecrets: The secrets other sessions typed into tabs
    ///     (``BrowserReplDriver/typedSecretRedaction()``), masked wherever
    ///     the session's own are.
    ///   - isCancelled: Whether a long byte scan is to stop
    ///     (``BrowserReplWatchdog/shouldStopNativeWork``).
    init(
        publicSuffixes: BrowserReplPublicSuffixList = .system,
        typedSecrets: @escaping @Sendable () -> BrowserReplSecretStore? = { nil },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.publicSuffixes = publicSuffixes
        self.secrets = BrowserReplSecretStore(publicSuffixes: publicSuffixes)
        self.typedSecrets = typedSecrets
        self.isCancelled = isCancelled
    }

    /// Methods whose results are images or documents; their pixels are
    /// masked by the driver instead.
    static let binaryMethods: Set<String> = ["tab.screenshot", "tab.pdf"]
    /// Parameters only the session may set on a driver call.
    static let reservedParameters = ["secretName", "secretDomains", "secretRevision", "secretMasks", "secretMasksTakenAt"]

    var domainPolicy: BrowserReplDomainPolicy { lock.withLock { policy } }

    func blockReason(_ url: String) -> String? { domainPolicy.blockReason(url) }

    /// Sets the directories a navigation may load files from (the session's
    /// working directory, which `cd` changes, and its temporary directory).
    func setFileRoots(_ roots: [String]) {
        lock.withLock { fileRoots = roots }
    }

    // MARK: Secrets host (`__cmuxNative.secrets`)

    /// `op` is `set { name, value, domains, totp }`, `load { object }`,
    /// `list`, `has { name }`, `delete { name }` or `clear`. No result holds a value.
    func secretsOperation(_ op: String, _ args: [String: Any]) -> Result<Any, BrowserReplDriverError> {
        do {
            switch op {
            case "set":
                let name = args["name"] as? String ?? ""
                guard let value = args["value"] as? String else {
                    throw BrowserReplDriverError(code: "invalid", message: "secrets.set: \(name): value: expected a non-empty string")
                }
                let domains = args["domains"] as? [String] ?? []
                try secrets.set(name: name, value: value, domains: domains, totp: args["totp"] as? Bool ?? false, title: "secrets.set")
                return .success(secrets.describe([name]).first ?? [:])
            case "load":
                let names = try secrets.load(args["object"] ?? NSNull(), isCancelled: isCancelled)
                return .success(secrets.describe(names))
            case "list":
                return .success(secrets.describe())
            case "has":
                return .success(secrets.has(args["name"] as? String ?? ""))
            case "delete":
                return .success(secrets.delete(args["name"] as? String ?? ""))
            case "clear":
                secrets.clear()
                return .success(NSNull())
            default:
                throw BrowserReplDriverError(code: "invalid", message: "secrets: unknown operation \(op)")
            }
        } catch let error as BrowserReplDriverError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(Self.cancelled("secrets.\(op)"))
        } catch {
            return .failure(BrowserReplDriverError(code: "invalid", message: error.localizedDescription))
        }
    }

    /// The refusal of a host call whose native work stopped at the cell's
    /// deadline or the session's end.
    static func cancelled(_ title: String) -> BrowserReplDriverError {
        BrowserReplDriverError(code: "cancelled", message: "\(title): cancelled because the cell timed out or the session ended")
    }

    // MARK: Policy host (`__cmuxNative.policy`)

    /// `get`, `check { url }` (the reason or null), `site { host }` (the
    /// host's registrable domain by the Public Suffix List, or the host when
    /// it has none, as the driver scopes cookies), `publicSuffix { name }`
    /// (whether the name is a public suffix itself) or `set { allowed?,
    /// prohibited?, blockIPs?, lock?, title }`; a given key replaces its
    /// value, `null` clears it. A locked policy refuses `set`.
    /// - Returns: The result and, for `set`, the new policy to give the driver.
    func policyOperation(_ op: String, _ args: [String: Any]) -> (Result<Any, BrowserReplDriverError>, BrowserReplDomainPolicy?) {
        switch op {
        case "get":
            return (.success(domainPolicy.json), nil)
        case "check":
            return (.success(blockReason(args["url"] as? String ?? "").map { $0 as Any } ?? NSNull()), nil)
        case "site":
            return (.success(publicSuffixes.site(of: args["host"] as? String ?? "")), nil)
        case "publicSuffix":
            return (.success(publicSuffixes.isPublicSuffix(args["name"] as? String ?? "")), nil)
        case "set":
            let title = args["title"] as? String ?? "session.domainPolicy"
            do {
                let updated: BrowserReplDomainPolicy = try lock.withLock {
                    guard !policy.locked else {
                        throw BrowserReplDriverError(code: "invalid", message: "\(title): the domain policy is locked for this session")
                    }
                    var next = policy
                    if args.keys.contains("allowed") {
                        let list = try patterns(args["allowed"], title: title)
                        next.allowed = (list?.isEmpty ?? true) ? nil : list
                        // A page that holds a typed secret may send it
                        // wherever the policy lets it reach.
                        if let domains = typedSecretDomains.first(where: { !Self.keeps(next.allowed, within: $0) }) {
                            throw BrowserReplDriverError(
                                code: "invalid",
                                message: "\(title): a secret or sign-in credential was typed under the domain policy, so it may only keep pages on its domains (\(domains.map(\.raw).joined(separator: ", "))) for the rest of the session"
                            )
                        }
                    }
                    if args.keys.contains("prohibited") {
                        next.prohibited = try patterns(args["prohibited"], title: title) ?? []
                    }
                    if let block = args["blockIPs"] as? Bool { next.blockIPAddresses = block }
                    if args["lock"] as? Bool == true { next.locked = true }
                    policy = next
                    return next
                }
                return (.success(updated.json), updated)
            } catch let error as BrowserReplDriverError {
                return (.failure(error), nil)
            } catch {
                return (.failure(BrowserReplDriverError(code: "invalid", message: error.localizedDescription)), nil)
            }
        default:
            return (.failure(BrowserReplDriverError(code: "invalid", message: "policy: unknown operation \(op)")), nil)
        }
    }

    private func patterns(_ raw: Any?, title: String) throws -> [BrowserReplDomainPattern]? {
        if raw == nil || raw is NSNull { return nil }
        guard let list = raw as? [Any] else {
            throw BrowserReplDriverError(code: "invalid", message: "\(title): expected an array of domain patterns or null, got \(JSONSerialization.browserReplString(raw) ?? "?")")
        }
        guard list.count <= BrowserReplDomainPolicy.maximumPatternsPerList else {
            throw BrowserReplDriverError(
                code: "invalid",
                message: "\(title): a list holds at most \(BrowserReplDomainPolicy.maximumPatternsPerList) domain patterns; this one has \(list.count)"
            )
        }
        return try list.map { item in
            guard let text = item as? String else {
                throw BrowserReplDriverError(code: "invalid", message: "\(title): expected domain patterns as non-empty strings, got \(JSONSerialization.browserReplString(item) ?? "?")")
            }
            return try BrowserReplDomainPattern.parse(text, title: title, publicSuffixes: publicSuffixes)
        }
    }

    // MARK: Driver calls

    /// The parameters the driver receives for a call from JavaScript, or why
    /// the call is refused.
    ///
    /// - `input.insertText { secret: name }` gets the value, the secret's
    ///   name and its domains; the driver types it only into a frame whose
    ///   origin matches.
    /// - Navigations and new tabs to a URL the policy blocks, to a file
    ///   outside the session's directories, or to another local scheme
    ///   (``BrowserReplFileSandbox/navigationRefusal(_:roots:)``) are refused.
    /// - `session.configure` may not set content rules: they come from the
    ///   policy.
    /// - Captures get the plain secret values to mask in matching frames.
    func prepare(method: String, paramsJSON: String) -> Result<String, BrowserReplDriverError> {
        let watched = ["input.insertText", "tab.navigate", "tabs.open", "session.configure", "tab.screenshot", "tab.pdf", "auth.request"]
        guard watched.contains(method) || paramsJSON.contains("secret") else { return .success(paramsJSON) }
        var params = JSONSerialization.browserReplObject(paramsJSON)
        for key in Self.reservedParameters { params.removeValue(forKey: key) }
        switch method {
        case "input.insertText":
            if let name = params.removeValue(forKey: "secret") {
                guard let name = name as? String, let typed = secrets.typing(name) else {
                    let quoted = JSONSerialization.browserReplString(name) ?? "?"
                    return .failure(BrowserReplDriverError(code: "invalid", message: "secret \(quoted) was deleted"))
                }
                if let refusal = secretTypingRefusal(name: name, domains: typed.domains) { return .failure(refusal) }
                params["text"] = typed.text
                params["secretName"] = name
                params["secretDomains"] = typed.domains.map(\.json)
                // The driver asks again right before typing
                // (``secretIsCurrent(name:revision:)``).
                params["secretRevision"] = typed.revision
            }
        case "auth.request":
            // The sign-in sheet's values go into the page like a typed
            // secret: under a policy that keeps the session's tabs on the
            // page's site, which the driver gets as their domains (checked
            // against the frame that receives them, and masked by them).
            switch credentialDomains(origin: params["origin"]) {
            case .success(let domains): params["secretDomains"] = domains.map(\.json)
            case .failure(let refusal): return .failure(refusal)
            }
        case "tab.navigate", "tabs.open":
            if let url = params["url"] as? String {
                // Local files only inside the session's own directories, and
                // none of cmux's internal schemes, whatever the policy.
                if let reason = BrowserReplFileSandbox.navigationRefusal(url, roots: lock.withLock({ fileRoots })) {
                    return .failure(BrowserReplDriverError(code: "blocked", message: "\(url) is blocked: \(reason)"))
                }
                if let reason = blockReason(url) {
                    return .failure(BrowserReplDriverError(code: "blocked", message: "\(url) is blocked: \(reason)"))
                }
            }
        case "session.configure":
            if params.keys.contains("contentRules") {
                return .failure(BrowserReplDriverError(
                    code: "invalid",
                    message: "session.configure: content rules come from the domain policy (session.allowedDomains, session.prohibitedDomains, session.blockIPAddresses)"
                ))
            }
        case "tab.screenshot", "tab.pdf":
            // The time goes with the masks, for the check after the capture
            // (``checkCaptureMasks(method:paramsJSON:_:)``).
            let takenAt = Date()
            let masks = secrets.captureMasks(at: takenAt)
            if !masks.isEmpty {
                params["secretMasks"] = masks.map { ["value": $0.value, "domains": $0.domains.map(\.json)] as [String: Any] }
            }
            params["secretMasksTakenAt"] = takenAt.timeIntervalSince1970
        default:
            break
        }
        return .success(JSONSerialization.browserReplString(params) ?? "{}")
    }

    /// Why the secret `name` may not be typed now, or nil. The driver types
    /// it only where the focused frame is on its domains, but the page that
    /// receives it can send it on; only the domain policy's content rules,
    /// in the tabs the session opened, stop that (the driver refuses any
    /// other tab). So the policy must allow nothing outside the secret's
    /// domains, and it may not widen past them later: the secret's domains
    /// are kept from here on (``policyOperation(_:_:)``).
    private func secretTypingRefusal(name: String, domains: [BrowserReplDomainPattern]) -> BrowserReplDriverError? {
        lock.withLock {
            let list = domains.map(\.raw).joined(separator: ", ")
            guard let allowed = policy.allowed else {
                return BrowserReplDriverError(
                    code: "invalid",
                    message: "secret \"\(name)\" is typed only while the domain policy keeps the session's tabs on its domains, so the page cannot send it elsewhere; call session.allowedDomains([\(domains.map { "\"\(Self.secureRaw($0))\"" }.joined(separator: ", "))]) first"
                )
            }
            guard Self.keeps(allowed, within: domains) else {
                let outside = allowed.filter { pattern in !domains.contains { $0.covers(pattern, secure: true) } }.map(\.raw).joined(separator: ", ")
                return BrowserReplDriverError(
                    code: "invalid",
                    message: "secret \"\(name)\" is typed only while the domain policy keeps the session's tabs on its domains (\(list)); the policy also allows \(outside)\(Self.httpsHint)"
                )
            }
            if !typedSecretDomains.contains(domains) { typedSecretDomains.append(domains) }
            return nil
        }
    }

    /// The domains of the values the sign-in sheet fills into a page of
    /// `origin` (`auth.request`): its site (`*.<registrable domain>`, or
    /// the host itself when it has none, an IP address or a single label).
    /// Refused unless the policy keeps the session's tabs within them, as
    /// for a typed secret, and kept from then on (``policyOperation(_:_:)``).
    private func credentialDomains(origin raw: Any?) -> Result<[BrowserReplDomainPattern], BrowserReplDriverError> {
        guard let origin = raw as? String, let url = URL(string: origin), url.scheme == "https" || url.scheme == "http",
              let host = url.host, !host.isEmpty else {
            return .failure(BrowserReplDriverError(code: "invalid", message: "auth.request: origin: expected the page's http(s) origin"))
        }
        let site = publicSuffixes.site(of: host)
        guard let domain = (try? BrowserReplDomainPattern.parse("*.\(site)", title: "auth.request", publicSuffixes: publicSuffixes))
            ?? (try? BrowserReplDomainPattern.parse(site, title: "auth.request", publicSuffixes: publicSuffixes)) else {
            return .failure(BrowserReplDriverError(code: "invalid", message: "auth.request: \(origin) has no site a domain policy can name"))
        }
        let domains = [domain]
        return lock.withLock {
            guard let allowed = policy.allowed, Self.keeps(allowed, within: domains) else {
                let also = policy.allowed.map { list in
                    "; the policy also allows " + list.filter { pattern in !domains.contains { $0.covers(pattern, secure: true) } }.map(\.raw).joined(separator: ", ")
                } ?? ""
                return .failure(BrowserReplDriverError(
                    code: "invalid",
                    message: "sites.browserAuth fills what the user types into the page, which can send it wherever the domain policy lets it; it asks only while the policy keeps the session's tabs on \(domain.raw)\(also). Call session.allowedDomains([\"\(Self.secureRaw(domain))\"]) (or narrower) first"
                ))
            }
            if !typedSecretDomains.contains(domains) { typedSecretDomains.append(domains) }
            return .success(domains)
        }
    }

    /// `domain` as an allowed pattern that keeps pages where it is typed:
    /// with https when it names no scheme and is not a loopback host.
    private static func secureRaw(_ domain: BrowserReplDomainPattern) -> String {
        domain.scheme == nil && !domain.loadsOnlySecurely ? "https://" + domain.raw : domain.raw
    }

    private static let httpsHint = " (a domain without a scheme also allows http; name it with https://, such as https://example.com)"

    /// Whether a policy's `allowed` list keeps pages on `domains`: it is set,
    /// and each of its patterns is covered by one of them, on https unless
    /// a domain names its scheme (``BrowserReplDomainPattern/covers(_:secure:)``).
    private static func keeps(_ allowed: [BrowserReplDomainPattern]?, within domains: [BrowserReplDomainPattern]) -> Bool {
        guard let allowed else { return false }
        return allowed.allSatisfy { pattern in domains.contains { $0.covers(pattern, secure: true) } }
    }

    /// Whether the secret an `input.insertText` call carries (its
    /// `secretName` and `secretRevision`) is still the one the session
    /// holds: the driver asks right before it types the value, so a secret
    /// deleted, cleared or replaced since the call was made is never typed.
    func secretIsCurrent(name: String, revision: Int) -> Bool {
        secrets.isCurrent(name, revision: revision)
    }

    /// A capture's result, refused (`stale`) when the session could have
    /// typed a secret value its masks lack while it was taken: the masks
    /// are the values the session held when the call was made (`prepare`),
    /// and calls run concurrently, so the session can set a new secret, or
    /// add a domain to one, and type it meanwhile, or a TOTP secret's code
    /// can move past the windows the masks hold. Every value, and every
    /// TOTP code of a window between the masks and now, must be among the
    /// masks with each of its domains.
    func checkCaptureMasks(method: String, paramsJSON: String, _ result: Result<String, BrowserReplDriverError>) -> Result<String, BrowserReplDriverError> {
        guard Self.binaryMethods.contains(method), case .success = result else { return result }
        let params = JSONSerialization.browserReplObject(paramsJSON)
        let takenAt = (params["secretMasksTakenAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? .distantPast
        var masked = Set<String>()
        for mask in params["secretMasks"] as? [[String: Any]] ?? [] {
            guard let value = mask["value"] as? String else { continue }
            for domain in mask["domains"] as? [Any] ?? [] {
                masked.insert(value + "\u{0}" + Self.canonicalJSON(domain))
            }
        }
        let typeable = secrets.typeableValues(from: takenAt, to: Date())
        let covered = typeable.allSatisfy { entry in
            entry.domains.allSatisfy { masked.contains(entry.value + "\u{0}" + Self.canonicalJSON($0.json)) }
        }
        guard covered else {
            return .failure(BrowserReplDriverError(
                code: "stale",
                message: "The session set a secret while the capture was taken, so it may show the value unmasked; try again"
            ))
        }
        return result
    }

    /// `value` as JSON with sorted keys, so a domain pattern compares equal
    /// after a round trip through a driver call's parameters.
    private static func canonicalJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
