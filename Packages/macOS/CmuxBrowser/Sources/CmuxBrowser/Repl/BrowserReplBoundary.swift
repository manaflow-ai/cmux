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
    private let typedSecrets: @Sendable () -> BrowserReplSecretStore?
    /// The session's working and temporary directories, the only places a
    /// navigation may load a file from.
    private var fileRoots: [String] = []

    /// - Parameters:
    ///   - publicSuffixes: The list `site` and `publicSuffix` answers come
    ///     from, and that refuses wildcard patterns over a public suffix.
    ///   - typedSecrets: The secrets other sessions typed into tabs
    ///     (``BrowserReplDriver/typedSecretRedaction()``), masked wherever
    ///     the session's own are.
    init(
        publicSuffixes: BrowserReplPublicSuffixList = .system,
        typedSecrets: @escaping @Sendable () -> BrowserReplSecretStore? = { nil }
    ) {
        self.publicSuffixes = publicSuffixes
        self.secrets = BrowserReplSecretStore(publicSuffixes: publicSuffixes)
        self.typedSecrets = typedSecrets
    }

    // MARK: Redaction

    /// The stores whose values JavaScript and output never see: the
    /// session's own secrets, then the values other sessions typed.
    private var redactionStores: [BrowserReplSecretStore] {
        var stores = secrets.isEmpty ? [] : [secrets]
        if let typed = typedSecrets(), !typed.isEmpty { stores.append(typed) }
        return stores
    }

    /// `text` as JavaScript or output may see it.
    func redact(_ text: String) -> String {
        redactionStores.reduce(text) { $1.redact($0) }
    }

    /// A JSON document as JavaScript may see it, every string (keys too)
    /// redacted; text that is not JSON is redacted as text.
    /// - Throws: `invalid` when masking would grow it past the redaction
    ///   limit (``BrowserReplSecretStore/maximumGrowth``).
    func redactJSON(_ json: String) throws -> String {
        let stores = redactionStores
        guard !stores.isEmpty else { return json }
        guard let value = JSONSerialization.browserReplValue(json) else { return redact(json) }
        let redacted = try stores.reduce(value) { try $1.redactedValue($0) }
        return JSONSerialization.browserReplString(redacted) ?? redact(json)
    }

    /// Bytes as JavaScript may see them, text or binary.
    /// - Throws: `invalid` when masking would grow them past the redaction
    ///   limit (``BrowserReplSecretStore/maximumGrowth``).
    func redact(_ data: Data) throws -> Data {
        try redactionStores.reduce(data) { try $1.redact($0) }
    }

    /// Methods whose results are images or documents; their pixels are
    /// masked by the driver instead.
    static let binaryMethods: Set<String> = ["tab.screenshot", "tab.pdf"]
    /// Parameters only the session may set on a driver call.
    static let reservedParameters = ["secretName", "secretDomains", "secretMasks", "secretMasksTakenAt"]

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
                let names = try secrets.load(args["object"] ?? NSNull())
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
        } catch {
            return .failure(BrowserReplDriverError(code: "invalid", message: error.localizedDescription))
        }
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
        let watched = ["input.insertText", "tab.navigate", "tabs.open", "session.configure", "tab.screenshot", "tab.pdf"]
        guard watched.contains(method) || paramsJSON.contains("secret") else { return .success(paramsJSON) }
        var params = JSONSerialization.browserReplObject(paramsJSON)
        for key in Self.reservedParameters { params.removeValue(forKey: key) }
        switch method {
        case "input.insertText":
            if let name = params.removeValue(forKey: "secret") {
                guard let name = name as? String, let typed = secrets.valueToType(name) else {
                    let quoted = JSONSerialization.browserReplString(name) ?? "?"
                    return .failure(BrowserReplDriverError(code: "invalid", message: "secret \(quoted) was deleted"))
                }
                params["text"] = typed.text
                params["secretName"] = name
                params["secretDomains"] = typed.domains.map(\.json)
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

    /// A driver result as JavaScript may see it.
    func redact(method: String, _ result: Result<String, BrowserReplDriverError>) -> Result<String, BrowserReplDriverError> {
        switch result {
        case .success(let json):
            guard !Self.binaryMethods.contains(method) else { return result }
            do {
                return .success(try redactJSON(json))
            } catch {
                return .failure(BrowserReplDriverError(code: "invalid", message: "\(method): \(BrowserReplSecretStore.limitMessage(json.utf8.count))"))
            }
        case .failure(let error):
            return .failure(redact(error))
        }
    }

    func redact(_ error: BrowserReplDriverError) -> BrowserReplDriverError {
        let message = redact(error.message)
        return message == error.message ? error : BrowserReplDriverError(code: error.code, message: message, errorName: error.errorName)
    }

    /// A fetch result as JavaScript may see it: the URL, the headers and the
    /// body, text or binary (its bytes go through the secret store's byte redaction),
    /// are redacted.
    func redactFetch(_ result: Result<String, BrowserReplDriverError>) -> Result<String, BrowserReplDriverError> {
        let stores = redactionStores
        guard !stores.isEmpty else { return result }
        guard case .success(let json) = result else { return redact(method: "fetch", result) }
        var response = JSONSerialization.browserReplObject(json)
        let body = response.removeValue(forKey: "bodyBase64") as? String
        do {
            var redacted = try stores.reduce(response as Any) { try $1.redactedValue($0) } as? [String: Any] ?? [:]
            if let body {
                guard let data = Data(base64Encoded: body) else {
                    return .failure(BrowserReplDriverError(code: "invalid", message: "fetch: the response body could not be checked for secrets"))
                }
                let masked = try redact(data)
                redacted["bodyBase64"] = masked == data ? body : masked.base64EncodedString()
            }
            return .success(JSONSerialization.browserReplString(redacted) ?? "null")
        } catch let error as BrowserReplDriverError {
            return .failure(BrowserReplDriverError(code: error.code, message: "fetch: \(error.message)"))
        } catch {
            return .failure(BrowserReplDriverError(code: "invalid", message: "fetch: \(error.localizedDescription)"))
        }
    }

    /// File contents the session writes for JavaScript, or reads back for it
    /// (`fs.readFile`), with secrets redacted, text or binary.
    /// - Throws: `invalid` when masking would grow them past the redaction
    ///   limit (``BrowserReplSecretStore/maximumGrowth``).
    func redactFileContents(_ base64: String) throws -> String {
        let stores = redactionStores
        guard !stores.isEmpty, let data = Data(base64Encoded: base64) else { return base64 }
        let redacted = try redact(data)
        return redacted == data ? base64 : redacted.base64EncodedString()
    }
}
