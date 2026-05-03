import Foundation

// MARK: - Errors

enum CodexUsageFetchError: Error, LocalizedError {
    case invalidAccessToken
    case invalidAccountId
    case http(Int)
    case badResponse
    case decoding
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .invalidAccessToken:
            return String(localized: "codex.usage.error.invalidAccessToken", defaultValue: "Codex access token is missing or malformed. Copy tokens.access_token from ~/.codex/auth.json.")
        case .invalidAccountId:
            return String(localized: "codex.usage.error.invalidAccountId", defaultValue: "Codex account ID contains invalid characters. Copy tokens.account_id from ~/.codex/auth.json, or leave it blank.")
        case .http(let code):
            if code == 401 || code == 403 {
                return String(localized: "codex.usage.error.httpAuth", defaultValue: "Codex token expired or invalid (HTTP \(code)). Re-grab tokens.access_token from ~/.codex/auth.json.")
            }
            if code == 404 {
                return String(localized: "codex.usage.error.http404", defaultValue: "Codex account not found. Verify chatgpt-account-id.")
            }
            return String(localized: "codex.usage.error.http", defaultValue: "Codex API returned HTTP \(code).")
        case .badResponse:
            return String(localized: "codex.usage.error.badResponse", defaultValue: "Codex API returned an invalid response.")
        case .decoding:
            return String(localized: "codex.usage.error.decoding", defaultValue: "Failed to parse Codex rate_limit response.")
        case .network:
            return String(localized: "codex.usage.error.network", defaultValue: "Network error")
        }
    }
}

// MARK: - Fetcher

enum CodexUsageFetcher {

    private static let session = ProviderHTTP.makeSession(timeout: 10)

    static func fetch(secret: ProviderSecret) async throws -> ProviderUsageWindows {
        // Re-run the editor validators against the stored value so a persisted
        // or manually edited secret can't slip past the UI and produce
        // malformed `Authorization` / `chatgpt-account-id` headers.
        let accessToken = (secret.fields["accessToken"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard CodexValidators.isValidAccessToken(accessToken) else {
            throw CodexUsageFetchError.invalidAccessToken
        }
        let accountId = (secret.fields["accountId"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard CodexValidators.isValidAccountId(accountId) else {
            throw CodexUsageFetchError.invalidAccountId
        }

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw CodexUsageFetchError.badResponse
        }

        var headers = ["Authorization": "Bearer \(accessToken)"]
        if !accountId.isEmpty {
            headers["chatgpt-account-id"] = accountId
        }

        let root: [String: Any]
        do {
            root = try await ProviderHTTP.getJSONObject(
                url: url,
                headers: headers,
                session: session
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch ProviderHTTPError.http(let status) {
            throw CodexUsageFetchError.http(status)
        } catch ProviderHTTPError.badResponse {
            throw CodexUsageFetchError.badResponse
        } catch ProviderHTTPError.network(let underlying) {
            // Log only domain/code: NSError userInfo can embed the failing
            // URL, which carries the account-scoped accountId header context.
            let nsError = underlying as NSError
            NSLog("CodexUsageFetcher network error: domain=%@ code=%ld", nsError.domain, nsError.code)
            throw CodexUsageFetchError.network(underlying)
        } catch {
            throw CodexUsageFetchError.decoding
        }
        guard let limits = root["rate_limit"] as? [String: Any] else {
            throw CodexUsageFetchError.decoding
        }

        func parseWindow(_ key: String) throws -> ProviderUsageWindow {
            guard let dict = limits[key] as? [String: Any],
                  let usedPercent = Self.doubleValue(dict["used_percent"]) else {
                throw CodexUsageFetchError.decoding
            }
            guard let windowSeconds = Self.doubleValue(dict["limit_window_seconds"]),
                  windowSeconds > 0 else {
                // A zero or negative window breaks pacing math; treat it as
                // backend contract drift rather than usable data.
                throw CodexUsageFetchError.decoding
            }
            let rawResetAfterSeconds = dict["reset_after_seconds"]
            let resetsInSeconds: Double?
            if rawResetAfterSeconds == nil || rawResetAfterSeconds is NSNull {
                resetsInSeconds = nil
            } else if let parsed = Self.doubleValue(rawResetAfterSeconds) {
                // Negative `reset_after_seconds` would silently look like "no
                // reset scheduled"; require a non-negative value instead.
                guard parsed >= 0 else {
                    throw CodexUsageFetchError.decoding
                }
                resetsInSeconds = parsed
            } else {
                throw CodexUsageFetchError.decoding
            }
            let resetsAt: Date? = resetsInSeconds.flatMap { seconds in
                seconds > 0 ? Date(timeIntervalSinceNow: seconds) : nil
            }
            // Clamp as Double before narrowing: `Int(_:)` traps when the
            // source is outside `Int`'s range, so a wild value from the API
            // would crash before the min/max bounds could kick in.
            let clamped = min(max(usedPercent.rounded(), 0), 100)
            let utilization = Int(clamped)
            return ProviderUsageWindow(
                utilization: utilization,
                resetsAt: resetsAt,
                windowSeconds: windowSeconds
            )
        }

        let sessionWindow = try parseWindow("primary_window")
        let weekWindow = try parseWindow("secondary_window")
        return ProviderUsageWindows(session: sessionWindow, week: weekWindow)
    }

    /// Accepts JSON numbers or stringified numbers. The Codex API has been
    /// observed to hand back `limit_window_seconds` / `reset_after_seconds`
    /// as either a number or a decimal string; a silent `as? NSNumber`
    /// fall-through would mask a real format drift as "reset time unknown."
    ///
    /// `NSNumber` also bridges Swift `Bool`, so a JSON `true`/`false` would
    /// otherwise coerce to `1.0`/`0.0`. We explicitly reject booleans so a
    /// field that unexpectedly comes back as a bool raises a decoding error
    /// instead of quietly producing `0` or `1`.
    private static func doubleValue(_ value: Any?) -> Double? {
        let raw: Double
        if let number = value as? NSNumber {
            // NSNumber and CFBoolean share a toll-free bridge; check the
            // CoreFoundation type ID to reject a bridged Bool reliably.
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                return nil
            }
            raw = number.doubleValue
        } else if let string = value as? String, let parsed = Double(string) {
            raw = parsed
        } else {
            return nil
        }
        // `Double("nan")` and `Double("inf")` parse successfully and NSNumber
        // can also carry non-finite values; reject them so downstream integer
        // conversion and percentage clamping get a usable number.
        return raw.isFinite ? raw : nil
    }
}
