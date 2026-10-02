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
    let secrets = BrowserReplSecretStore()
    private let lock = NSLock()
    private var policy = BrowserReplDomainPolicy()

    /// Methods whose results are images or documents; their pixels are
    /// masked by the driver instead.
    static let binaryMethods: Set<String> = ["tab.screenshot", "tab.pdf"]
    /// Parameters only the session may set on a driver call.
    static let reservedParameters = ["secretName", "secretDomains", "secretMasks"]

    var domainPolicy: BrowserReplDomainPolicy { lock.withLock { policy } }

    func blockReason(_ url: String) -> String? { domainPolicy.blockReason(url) }

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

    /// `get`, `check { url }` (the reason or null) or `set { allowed?,
    /// prohibited?, blockIPs?, lock?, title }`; a given key replaces its
    /// value, `null` clears it. A locked policy refuses `set`.
    /// - Returns: The result and, for `set`, the new policy to give the driver.
    func policyOperation(_ op: String, _ args: [String: Any]) -> (Result<Any, BrowserReplDriverError>, BrowserReplDomainPolicy?) {
        switch op {
        case "get":
            return (.success(domainPolicy.json), nil)
        case "check":
            return (.success(blockReason(args["url"] as? String ?? "").map { $0 as Any } ?? NSNull()), nil)
        case "set":
            let title = args["title"] as? String ?? "session.domainPolicy"
            do {
                let updated: BrowserReplDomainPolicy = try lock.withLock {
                    guard !policy.locked else {
                        throw BrowserReplDriverError(code: "invalid", message: "\(title): the domain policy is locked for this session")
                    }
                    var next = policy
                    if args.keys.contains("allowed") {
                        let list = try Self.patterns(args["allowed"], title: title)
                        next.allowed = (list?.isEmpty ?? true) ? nil : list
                    }
                    if args.keys.contains("prohibited") {
                        next.prohibited = try Self.patterns(args["prohibited"], title: title) ?? []
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

    private static func patterns(_ raw: Any?, title: String) throws -> [BrowserReplDomainPattern]? {
        if raw == nil || raw is NSNull { return nil }
        guard let list = raw as? [Any] else {
            throw BrowserReplDriverError(code: "invalid", message: "\(title): expected an array of domain patterns or null, got \(JSONSerialization.browserReplString(raw) ?? "?")")
        }
        return try list.map { item in
            guard let text = item as? String else {
                throw BrowserReplDriverError(code: "invalid", message: "\(title): expected domain patterns as non-empty strings, got \(JSONSerialization.browserReplString(item) ?? "?")")
            }
            return try BrowserReplDomainPattern.parse(text, title: title)
        }
    }

    // MARK: Driver calls

    /// The parameters the driver receives for a call from JavaScript, or why
    /// the call is refused.
    ///
    /// - `input.insertText { secret: name }` gets the value, the secret's
    ///   name and its domains; the driver types it only into a frame whose
    ///   origin matches.
    /// - Navigations and new tabs to a URL the policy blocks are refused.
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
            if let url = params["url"] as? String, let reason = blockReason(url) {
                return .failure(BrowserReplDriverError(code: "blocked", message: "\(url) is blocked: \(reason)"))
            }
        case "session.configure":
            if params.keys.contains("contentRules") {
                return .failure(BrowserReplDriverError(
                    code: "invalid",
                    message: "session.configure: content rules come from the domain policy (session.allowedDomains, session.prohibitedDomains, session.blockIPAddresses)"
                ))
            }
        case "tab.screenshot", "tab.pdf":
            let masks = secrets.captureMasks
            if !masks.isEmpty {
                params["secretMasks"] = masks.map { ["value": $0.value, "domains": $0.domains.map(\.json)] as [String: Any] }
            }
        default:
            break
        }
        return .success(JSONSerialization.browserReplString(params) ?? "{}")
    }

    /// A driver result as JavaScript may see it.
    func redact(method: String, _ result: Result<String, BrowserReplDriverError>) -> Result<String, BrowserReplDriverError> {
        guard !secrets.isEmpty else { return result }
        switch result {
        case .success(let json):
            return Self.binaryMethods.contains(method) ? result : .success(secrets.redactJSON(json))
        case .failure(let error):
            return .failure(redact(error))
        }
    }

    func redact(_ error: BrowserReplDriverError) -> BrowserReplDriverError {
        guard !secrets.isEmpty else { return error }
        return BrowserReplDriverError(code: error.code, message: secrets.redact(error.message), errorName: error.errorName)
    }

    /// A fetch result as JavaScript may see it: the URL and headers are
    /// redacted, and so is a text body; a binary body is passed unchanged.
    func redactFetch(_ result: Result<String, BrowserReplDriverError>) -> Result<String, BrowserReplDriverError> {
        guard !secrets.isEmpty else { return result }
        guard case .success(let json) = result else { return redact(method: "fetch", result) }
        var response = JSONSerialization.browserReplObject(json)
        let body = response.removeValue(forKey: "bodyBase64") as? String
        var redacted = secrets.redactValue(response) as? [String: Any] ?? [:]
        if let body {
            let contentType = ((response["headers"] as? [[String]]) ?? [])
                .first { $0.first?.lowercased() == "content-type" }?.last?.lowercased() ?? ""
            let textual = contentType.isEmpty || contentType.hasPrefix("text/")
                || ["json", "xml", "javascript", "x-www-form-urlencoded", "csv", "yaml", "graphql"].contains { contentType.contains($0) }
            if textual, let data = Data(base64Encoded: body), let text = String(data: data, encoding: .utf8) {
                redacted["bodyBase64"] = Data(secrets.redact(text).utf8).base64EncodedString()
            } else {
                redacted["bodyBase64"] = body
            }
        }
        return .success(JSONSerialization.browserReplString(redacted) ?? "null")
    }

    /// File contents the session writes for JavaScript: UTF-8 text is redacted.
    func redactFileContents(_ base64: String) -> String {
        guard !secrets.isEmpty, let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8) else { return base64 }
        let redacted = secrets.redact(text)
        return redacted == text ? base64 : Data(redacted.utf8).base64EncodedString()
    }
}
