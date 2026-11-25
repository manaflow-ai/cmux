import Foundation

/// Why a turn failed, in plain words, with the agent's own message kept as the detail.
///
/// Ports the Mac agent pane's `failureCopy.ts` (cx-w10a: `failureKind`, `failureCopy`), so a
/// failed turn reads the same on the phone, and adds the cmux model service's own refusals: a
/// harness on the `cmux` route that the hosted service turns away (403 "this team cannot use the
/// model router on this deployment yet") said that "API Error: 403 {json}" before.
public struct TurnFailureCopy: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case trustPending, trustUntrusted, noTeamAccount
        case modelServiceUnavailable, modelServiceNotConnected, modelServiceExpired, modelServiceUnreachable
        case rateLimited, unreachable, invalidKey, subscriptionLogin, proxyAuth, auth, modelUnavailable, other
    }

    public let kind: Kind
    /// The sentence the card shows.
    public let sentence: String
    /// The agent's raw message, when it says more than the sentence (under Details).
    public let detail: String?

    /// - Parameters:
    ///   - message: the turn's error text (`turn_result.errorText`, else `error`).
    ///   - harness: the harness profile id (`claude`, `cmux`, `claude-sr`, ...).
    ///   - harnessName: its display name, when known.
    public init(message: String?, harness: String? = nil, harnessName: String? = nil) {
        guard let raw = message?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            kind = .other
            sentence = "The turn ended with an error."
            detail = nil
            return
        }
        let parts = Self.apiError(raw)
        let kind = Self.kind(raw, parts: parts, harness: harness)
        let name = [harnessName, harness].compactMap { $0?.isEmpty == false ? $0 : nil }.first ?? "The agent"
        let status = Self.firstMatch(#"\b([45]\d\d)\b"#, in: raw)
        let via = Self.via(raw, harness: harness)
        let sentence: String = switch kind {
        case .trustPending: "Answer the folder trust question on the Mac first."
        case .trustUntrusted: "This folder isn't trusted, so the agent can't take prompts here."
        case .noTeamAccount:
            "\(name) needs a team account on this machine. To add one for the team, run \(Self.firstMatch(Self.addCommand, in: raw) ?? "cr add") in this machine’s terminal."
        case .modelServiceUnavailable:
            (parts.message ?? raw).range(of: "this team", options: .caseInsensitive) != nil
                ? "cmux's model service isn't available for this team."
                : "cmux's model service isn't available here."
        case .modelServiceNotConnected: "cmux's model service isn't connected on the Mac. Open cmux on the Mac, then try again."
        case .modelServiceExpired: "cmux's model service sign-in expired on the Mac. Open cmux on the Mac to renew it."
        case .modelServiceUnreachable: "cmux's model service didn't answer. Try again in a moment."
        case .rateLimited: "\(name) is rate limited or out of capacity. Try again in a moment, or switch model."
        case .unreachable: via.map { "\(name) could not reach \($0)." } ?? "\(name) could not reach its server."
        case .invalidKey: "\(name) has no valid API key. Check the key its profile uses."
        case .proxyAuth: "\(via ?? "The route") refused \(name)’s request (\(status ?? "401")). Check that route’s key or account."
        case .subscriptionLogin: "\(name) is signed out or its sign-in expired."
        case .auth: "The provider refused \(name)’s credentials (\(status ?? "401"))."
        case .modelUnavailable: "\(name) can't use this model with the Mac's account. Pick another model."
        case .other: parts.message.map(Self.capitalized) ?? raw
        }
        self.kind = kind
        self.sentence = sentence
        detail = sentence == raw ? nil : raw
    }

    /// `message` for a toast or a refusal line: a JSON error body becomes its sentence;
    /// plain text stays as it is.
    public static func plain(_ message: String, harness: String? = nil, harnessName: String? = nil) -> String {
        guard message.contains("{"), message.contains("}") else { return message }
        return TurnFailureCopy(message: message, harness: harness, harnessName: harnessName).sentence
    }

    // MARK: - Classification (the Mac's order: trust, capacity and network first)

    static func kind(_ raw: String, parts: (code: String?, message: String?), harness: String?) -> Kind {
        if raw.range(of: #"\btrust\.pending\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return .trustPending }
        if raw.range(of: #"\btrust\.untrusted\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return .trustUntrusted }
        // CodeRouter's refusal on a team Cloud machine with no team account for the agent (a 403
        // `no_account_configured`, web/services/coderouter/noAccountMessage.ts). Codex shows only its
        // `error.message`, so the fixed opening is the signal. Before capacity and sign-in: a team
        // machine refuses own sign-ins, and no retry or model switch helps.
        if matches(Self.noTeamAccount, raw), firstMatch(Self.addCommand, in: raw) != nil { return .noTeamAccount }
        // The cmux model service and its local relay say what is wrong in their own codes.
        switch parts.code {
        case "router.no_upstream": return .modelServiceNotConnected
        case "router.upstream_expired": return .modelServiceExpired
        case "router.unreachable": return .modelServiceUnreachable
        default: break
        }
        let routerRefusal = raw.range(of: "model router", options: .caseInsensitive) != nil
            || (harness == "cmux" && (parts.code ?? "").hasPrefix("auth."))
        if routerRefusal, parts.code == "auth.forbidden" || raw.range(of: #"\b403\b"#, options: .regularExpression) != nil {
            return .modelServiceUnavailable
        }
        // The account can't run the chat's model (Codex with a ChatGPT account, a retired model).
        if matches(Self.rate, raw) { return .rateLimited }
        if matches(Self.modelUnavailable, parts.message ?? raw) { return .modelUnavailable }
        if matches(Self.unreachable, raw) { return .unreachable }
        let via = via(raw, harness: harness)
        if matches(Self.invalidKey, raw), !(matches(Self.subscription, raw) && via == nil) { return .invalidKey }
        if matches(Self.auth, raw), via != nil { return .proxyAuth }
        if matches(Self.subscription, raw) { return .subscriptionLogin }
        if matches(Self.auth, raw) { return .auth }
        return .other
    }

    /// `API Error: 403 {"error":{"code":…,"message":…}}` (Claude Code), or a bare JSON error body:
    /// the inner code and message. Both the cmux shape (`error.code`) and the Messages API shape
    /// (`error.type`) are read.
    static func apiError(_ raw: String) -> (code: String?, message: String?) {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        let error = object["error"] as? [String: Any] ?? object
        let message = (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = (error["code"] as? String) ?? (error["type"] as? String)
        return (code, message?.isEmpty == false ? message : nil)
    }

    /// The current server's opening, and the one before it.
    private static let noTeamAccount = #"needs a team account on this machine|account is shared with this Cloud machine's team"#
    /// The command the refusal names, captured.
    private static let addCommand = #"\b(cr add (?:codex|claude|opencode))\b"#
    private static let modelUnavailable = #"\bmodel\b.{0,80}\b(?:is not supported|isn't supported|not supported|does not exist|is not available|not available|not found|unknown model|no access)|(?:unknown|unsupported|invalid) model"#
    private static let rate = #"\b(?:429|529)\b|rate.?limit|too many requests|overloaded|at capacity|no non-exhausted|usage limit|quota|\b503\b|service unavailable"#
    private static let unreachable = #"ECONNREFUSED|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|ECONNRESET|EHOSTUNREACH|fetch failed|socket hang up|connection (?:refused|reset|closed|error)|could not (?:connect|resolve)|network (?:error|is unreachable)|\bunreachable\b|timed out"#
    private static let invalidKey = #"invalid[ _-]?(?:x-)?api[ _-]?key|incorrect api key|api key (?:is )?(?:missing|not set|not found|invalid)|no api key|(?:ANTHROPIC|OPENAI)_API_KEY"#
    private static let subscription = #"not logged in|login required|please (?:run )?/login|(?:claude|codex) (?:auth )?login|oauth token (?:has )?expired|session (?:has )?expired|refresh token|invalid_grant|sign(?:ed)? ?in again"#
    private static let auth = #"\b40[13]\b|unauthori[sz]ed|forbidden|authenticat|\boauth\b"#
    /// Profiles that reach their provider through a proxy acpmux knows by name (the Mac's list).
    private static let proxyProfiles = ["claude-sr": "subrouter", "claude-cr": "CodeRouter"]
    private static let providerHosts = #"(?:^|\.)(?:anthropic\.com|openai\.com|chatgpt\.com|claude\.ai)(?::\d+)?$"#

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// The proxy or endpoint a failure names: a host that is not the provider's, else the profile's known proxy.
    static func via(_ raw: String, harness: String?) -> String? {
        if let host = firstMatch(#"https?://([^\s/'")\]]+)"#, in: raw),
           host.range(of: providerHosts, options: [.regularExpression, .caseInsensitive]) == nil {
            return host
        }
        return harness.flatMap { proxyProfiles[$0] }
    }

    private static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        let sentence = first.uppercased() + text.dropFirst()
        return sentence.hasSuffix(".") || sentence.hasSuffix("!") || sentence.hasSuffix("?") ? sentence : sentence + "."
    }
}
