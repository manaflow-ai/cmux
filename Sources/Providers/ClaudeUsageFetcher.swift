import Foundation

// MARK: - Errors

enum ClaudeUsageFetchError: Error, LocalizedError {
    case invalidOrgId
    case invalidSessionKey
    case http(Int)
    case badResponse
    case decoding
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .invalidOrgId:
            return String(localized: "claude.usage.error.invalidOrgId", defaultValue: "Invalid organization ID in account credentials.")
        case .invalidSessionKey:
            return String(localized: "claude.usage.error.invalidSessionKey", defaultValue: "Session key contains invalid characters. Paste only the cookie value — separators (';', ',') and whitespace aren't allowed.")
        case .http(let code):
            if code == 401 || code == 403 {
                return String(localized: "claude.usage.error.httpAuth", defaultValue: "Session key expired or invalid (HTTP \(code)). Please update your credentials.")
            }
            return String(localized: "claude.usage.error.http", defaultValue: "Claude API returned HTTP \(code).")
        case .badResponse:
            return String(localized: "claude.usage.error.badResponse", defaultValue: "Claude API returned an invalid response.")
        case .decoding:
            return String(localized: "claude.usage.error.decoding", defaultValue: "Failed to parse usage data from Claude API.")
        case .network:
            return String(localized: "claude.usage.error.network", defaultValue: "Network error")
        }
    }
}

// MARK: - Fetcher

enum ClaudeUsageFetcher {

    private static let session = ProviderHTTP.makeSession(timeout: 10)

    static func fetch(secret: ProviderSecret) async throws -> ProviderUsageWindows {
        let orgId = (secret.fields["orgId"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Re-run the editor validator on the stored value so a persisted secret
        // can't smuggle traversal characters past percent-encoding and build a
        // URL like `/api/organizations/../usage`.
        guard ProviderClaudeValidators.isValidOrgId(orgId) else {
            throw ClaudeUsageFetchError.invalidOrgId
        }

        // Canonicalize the cookie value the same way the editor validator
        // does, then reject anything that would corrupt the `Cookie` header
        // (attribute separators, control bytes) or imply a second cookie was
        // pasted (a stray `=`).
        let sessionKey = ProviderClaudeValidators.strippedSessionKey(secret.fields["sessionKey"] ?? "")
        guard ProviderClaudeValidators.isValidSessionKey(sessionKey) else {
            throw ClaudeUsageFetchError.invalidSessionKey
        }

        var segmentAllowed = CharacterSet.alphanumerics
        segmentAllowed.insert(charactersIn: "-._~")
        guard let encodedOrgId = orgId.addingPercentEncoding(withAllowedCharacters: segmentAllowed),
              let url = URL(string: "https://claude.ai/api/organizations/\(encodedOrgId)/usage") else {
            throw ClaudeUsageFetchError.invalidOrgId
        }

        let json: [String: Any]
        do {
            json = try await ProviderHTTP.getJSONObject(
                url: url,
                headers: ["Cookie": "sessionKey=\(sessionKey)"],
                session: session
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch ProviderHTTPError.http(let status) {
            throw ClaudeUsageFetchError.http(status)
        } catch ProviderHTTPError.badResponse {
            throw ClaudeUsageFetchError.badResponse
        } catch ProviderHTTPError.network(let underlying) {
            // Log only domain/code: `localizedDescription` and userInfo can
            // embed the failing URL, which carries the account-scoped orgId.
            let nsError = underlying as NSError
            NSLog("ClaudeUsageFetcher network error: domain=%@ code=%ld", nsError.domain, nsError.code)
            throw ClaudeUsageFetchError.network(underlying)
        } catch {
            throw ClaudeUsageFetchError.decoding
        }

        guard let fiveHour = json["five_hour"] as? [String: Any],
              let fiveHourUtil = intUtilization(fiveHour["utilization"]) else {
            throw ClaudeUsageFetchError.decoding
        }

        let fiveHourResetsAt = ProviderISO8601DateParser.parse(fiveHour["resets_at"] as? String)

        // Distinguish "key absent" from "key present but malformed". A present
        // `seven_day` entry must be an object with a well-formed `utilization`;
        // a wrong-type payload should raise a decoding error rather than fall
        // through to 0% and hide an API schema change. Absence still reports
        // 0% for the week window.
        let sevenDay: [String: Any]?
        let sevenDayUtil: Int
        if let sevenDayRaw = json["seven_day"] {
            guard let dict = sevenDayRaw as? [String: Any],
                  let value = intUtilization(dict["utilization"]) else {
                throw ClaudeUsageFetchError.decoding
            }
            sevenDay = dict
            sevenDayUtil = value
        } else {
            sevenDay = nil
            sevenDayUtil = 0
        }
        let sevenDayResetsAt = ProviderISO8601DateParser.parse(sevenDay?["resets_at"] as? String)

        let sessionWindow = ProviderUsageWindow(utilization: fiveHourUtil, resetsAt: fiveHourResetsAt, windowSeconds: 18000)
        let weekWindow = ProviderUsageWindow(utilization: sevenDayUtil, resetsAt: sevenDayResetsAt, windowSeconds: 604800)

        return ProviderUsageWindows(session: sessionWindow, week: weekWindow)
    }

    /// Accepts an integer `utilization` value and clamps it to `0...100`.
    /// Rejects `nil`, non-numeric types, and JSON `true`/`false` — the latter
    /// would otherwise bridge to `NSNumber` and read out as `0` or `1`,
    /// silently turning a schema regression into a fake percentage.
    private static func intUtilization(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
            return nil
        }
        // Fractional value means schema mismatch; reject rather than truncate
        if number.doubleValue != Double(number.intValue) {
            return nil
        }
        return min(max(number.intValue, 0), 100)
    }
}

