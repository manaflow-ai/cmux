import Foundation

/// What the native side sends toward a session's JavaScript or its output,
/// before the egress gate (``BrowserReplBoundary/egress(_:)``) masks it.
enum BrowserReplEgressData {
    /// Output text: a printed line, an evaluation's error.
    case text(String)
    /// A driver call's result or refusal. Screenshots and PDFs keep their
    /// bytes: the driver masks their pixels (capture masks).
    case driverResult(method: String, Result<String, BrowserReplDriverError>)
    /// A `fetch` response: its URL, headers and body bytes (`bodyBase64`).
    case fetch(Result<String, BrowserReplDriverError>)
    /// A page event's payload. One past `maxBytes`, or that masking would
    /// grow past the redaction limit, arrives withheld
    /// (``withheldEvent(payloadJSON:reason:)``).
    case event(name: String, payloadJSON: String, maxBytes: Int)
    /// `{ targetId, withheld }` for a page event whose content is not
    /// delivered: the tab it names, and why.
    case withheldEvent(payloadJSON: String, reason: String)
    /// An `fs` operation's answer, as `{"ok": value}` or `{"error": …}`.
    /// File contents (`readFile`) are masked as bytes, every other value
    /// and message as text.
    case fs(op: String, Result<Any, BrowserReplFileSystemError>)
    /// A `secrets` or `policy` operation's answer, as `{"ok": value}` or
    /// `{"error": …}`.
    case host(Result<Any, BrowserReplDriverError>)
}

/// Data on its way to a session's JavaScript or output, past the egress
/// gate: every value the session holds, every value another session typed
/// into a tab, and (by their shape) TOTP codes are masked in it, by one scan
/// of the original data. Only this file makes one, so the session can hand
/// JavaScript nothing that skipped the gate: its result and event delivery
/// and its host functions take this type.
struct BrowserReplEgress {
    /// JSON (plain text for ``BrowserReplEgressData/text(_:)``), or the
    /// masked error.
    let result: Result<String, BrowserReplDriverError>

    fileprivate init(_ result: Result<String, BrowserReplDriverError>) {
        self.result = result
    }

    /// The text, or the error's message.
    var text: String {
        switch result {
        case .success(let text): text
        case .failure(let error): error.message
        }
    }

    /// The bytes the result holds as JavaScript gets it.
    var size: Int {
        switch result {
        case .success(let text): text.utf8.count
        case .failure(let error): error.code.utf8.count + error.message.utf8.count + (error.errorName?.utf8.count ?? 0)
        }
    }
}

extension BrowserReplBoundary {
    /// The values JavaScript and output never see, taken together now:
    /// the session's own secrets (current and retired), then the values
    /// other sessions typed. One redaction matches all of them against the
    /// original input, so a value the session registers can never mask
    /// part of a typed value before that value is looked for. `nil` when
    /// nothing is masked.
    fileprivate func redaction() -> BrowserReplSecretStore.Redaction? {
        var stores = [secrets]
        if let typed = typedSecrets() { stores.append(typed) }
        return BrowserReplSecretStore.Redaction(stores: stores)
    }

    /// The egress gate: `data` as the session's JavaScript or output may
    /// see it. The one place the native side masks what leaves it; the
    /// scan runs once, on the original data.
    func egress(_ data: BrowserReplEgressData) -> BrowserReplEgress {
        let redaction = redaction()
        switch data {
        case .text(let text):
            return BrowserReplEgress(.success(redaction?.redact(text) ?? text))
        case .driverResult(let method, let result):
            return BrowserReplEgress(Self.masking(result, method: method, with: redaction))
        case .fetch(let result):
            return BrowserReplEgress(Self.maskingFetch(result, with: redaction))
        case .event(let name, let payloadJSON, let maxBytes):
            let size = payloadJSON.utf8.count
            let reason: String
            if size > maxBytes {
                reason = "this \(name) event is \(size) bytes, past the \(maxBytes >> 20) MiB a page event may carry, so its content was withheld"
            } else if let masked = try? redaction?.redactJSON(payloadJSON) ?? payloadJSON {
                return BrowserReplEgress(.success(masked))
            } else {
                reason = BrowserReplSecretStore.limitMessage(size)
            }
            return BrowserReplEgress(.success(Self.withheld(payloadJSON, reason: reason, with: redaction)))
        case .withheldEvent(let payloadJSON, let reason):
            return BrowserReplEgress(.success(Self.withheld(payloadJSON, reason: reason, with: redaction)))
        case .fs(let op, let result):
            return BrowserReplEgress(.success(Self.maskingFS(op: op, result, with: redaction)))
        case .host(let result):
            return BrowserReplEgress(.success(Self.maskingHost(result, with: redaction)))
        }
    }

    /// What a file the session writes (`fs.writeFile`, `fs.copyFile`) gets
    /// in place of its bytes while any value is masked: the bytes masked by
    /// the gate's scan, so a file read back later never holds a value the
    /// gate would mask. `nil` when nothing is masked, so the bytes are
    /// written as they are.
    func fileStoreRedaction(syscall: String) -> ((Data) throws -> Data)? {
        guard let redaction = redaction() else { return nil }
        return { data in
            do {
                return try redaction.redact(data)
            } catch {
                throw BrowserReplFileSystemError(code: "EINVAL", message: "EINVAL: \(syscall): \(BrowserReplSecretStore.limitMessage(data.count))")
            }
        }
    }

    private static func masking(
        _ result: Result<String, BrowserReplDriverError>,
        method: String,
        with redaction: BrowserReplSecretStore.Redaction?
    ) -> Result<String, BrowserReplDriverError> {
        guard let redaction else { return result }
        switch result {
        case .success(let json):
            guard !binaryMethods.contains(method) else { return result }
            do {
                return .success(try redaction.redactJSON(json))
            } catch {
                return .failure(BrowserReplDriverError(code: "invalid", message: "\(method): \(BrowserReplSecretStore.limitMessage(json.utf8.count))"))
            }
        case .failure(let error):
            return .failure(masking(error, with: redaction))
        }
    }

    /// Every field of the error: a page exception's `code` and `name` are
    /// the page's (or the agent's page script's), like its message, and
    /// the runtime hands `code` to the agent as `Error.code`.
    private static func masking(_ error: BrowserReplDriverError, with redaction: BrowserReplSecretStore.Redaction) -> BrowserReplDriverError {
        let masked = BrowserReplDriverError(
            code: redaction.redact(error.code),
            message: redaction.redact(error.message),
            errorName: error.errorName.map { redaction.redact($0) }
        )
        return masked == error ? error : masked
    }

    /// The URL, the headers and the body, text or binary (its bytes are
    /// masked as bytes).
    private static func maskingFetch(
        _ result: Result<String, BrowserReplDriverError>,
        with redaction: BrowserReplSecretStore.Redaction?
    ) -> Result<String, BrowserReplDriverError> {
        guard let redaction else { return result }
        guard case .success(let json) = result else { return masking(result, method: "fetch", with: redaction) }
        var response = JSONSerialization.browserReplObject(json)
        let body = response.removeValue(forKey: "bodyBase64") as? String
        do {
            var masked = try redaction.redactedValue(response) as? [String: Any] ?? [:]
            if let body {
                guard let data = Data(base64Encoded: body) else {
                    return .failure(BrowserReplDriverError(code: "invalid", message: "fetch: the response body could not be checked for secrets"))
                }
                let maskedBody = try redaction.redact(data)
                masked["bodyBase64"] = maskedBody == data ? body : maskedBody.base64EncodedString()
            }
            return .success(JSONSerialization.browserReplString(masked) ?? "null")
        } catch let error as BrowserReplDriverError {
            return .failure(BrowserReplDriverError(code: error.code, message: "fetch: \(error.message)"))
        } catch {
            return .failure(BrowserReplDriverError(code: "invalid", message: "fetch: \(error.localizedDescription)"))
        }
    }

    /// `{ targetId, withheld }`: the tab the event names (masked), and why
    /// its content is not there.
    private static func withheld(_ payloadJSON: String, reason: String, with redaction: BrowserReplSecretStore.Redaction?) -> String {
        var withheld: [String: Any] = ["withheld": reason]
        if let targetId = JSONSerialization.browserReplObject(payloadJSON)["targetId"] as? String, targetId.utf8.count <= 256 {
            withheld["targetId"] = redaction?.redact(targetId) ?? targetId
        }
        return JSONSerialization.browserReplString(withheld) ?? "{}"
    }

    /// Every answer is masked: file contents (`readFile`) as bytes, any
    /// other value (names from `readdir`, paths from `resolve`) and error
    /// messages as JSON. A name or path can hold a value too: a page's
    /// download keeps the file name the page gave it.
    private static func maskingFS(
        op: String,
        _ result: Result<Any, BrowserReplFileSystemError>,
        with redaction: BrowserReplSecretStore.Redaction?
    ) -> String {
        guard let redaction else {
            switch result {
            case .success(let value): return hostJSON(.success(value))
            case .failure(let error): return hostJSON(.failure(code: error.code, message: error.message))
            }
        }
        switch result {
        case .success(let value):
            if op == "readFile", let base64 = value as? String, let data = Data(base64Encoded: base64) {
                do {
                    let masked = try redaction.redact(data)
                    return hostJSON(.success(masked == data ? base64 : masked.base64EncodedString()))
                } catch {
                    return hostJSON(.failure(code: "EINVAL", message: "readFile: \(BrowserReplSecretStore.limitMessage(data.count))"))
                }
            }
            do {
                return hostJSON(.success(try redaction.redactedValue(value)))
            } catch {
                return hostJSON(.failure(code: "EINVAL", message: "\(op): \(BrowserReplSecretStore.limitMessage(JSONSerialization.browserReplString(value)?.utf8.count ?? 0))"))
            }
        case .failure(let error):
            return hostJSON(.failure(code: error.code, message: redaction.redact(error.message)))
        }
    }

    private static func maskingHost(_ result: Result<Any, BrowserReplDriverError>, with redaction: BrowserReplSecretStore.Redaction?) -> String {
        switch result {
        case .success(let value):
            guard let redaction else { return hostJSON(.success(value)) }
            do {
                return hostJSON(.success(try redaction.redactedValue(value)))
            } catch {
                return hostJSON(.failure(code: "invalid", message: BrowserReplSecretStore.limitMessage(JSONSerialization.browserReplString(value)?.utf8.count ?? 0)))
            }
        case .failure(let error):
            let message = redaction?.redact(error.message) ?? error.message
            return hostJSON(.failure(code: error.code, message: message))
        }
    }

    private enum HostAnswer {
        case success(Any)
        case failure(code: String, message: String)
    }

    /// `{"ok": value}` or `{"error": {code, message}}`, as the host's
    /// synchronous functions return.
    private static func hostJSON(_ answer: HostAnswer) -> String {
        switch answer {
        case .success(let value):
            return JSONSerialization.browserReplString(["ok": value]) ?? #"{"ok":null}"#
        case .failure(let code, let message):
            return JSONSerialization.browserReplString(["error": ["code": code, "message": message]])
                ?? #"{"error":{"code":"invalid","message":"error"}}"#
        }
    }
}
