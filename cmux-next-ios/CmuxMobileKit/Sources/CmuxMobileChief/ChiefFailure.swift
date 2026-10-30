import CmuxAgentQuestion
import CmuxMobileTransport
import Foundation

/// A Chief turn that failed, as the Mac's brain posts it: the reply so far
/// (if any), then `(turn failed: <error>)`, `(turn failed on <harness>: …)`
/// or `(turn failed on <harness> (fallback for <other>): …)` at the end of
/// Chief's message (optchat-chief `brain/turns.rs` `turn_ended`). `<error>`
/// is the harness's own text, such as Claude Code's "API Error: 503 … check
/// your inference gateway (100.89.225.106:31415)." It names internal hosts
/// and ports and is written for the Mac's operator, so the phone shows a
/// plain sentence for its kind instead and keeps the raw text for the
/// diagnostics view only.
public struct ChiefTurnFailure: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        /// The model server could not be reached or failed (connection
        /// refused, timeout, 5xx): usually temporary.
        case modelUnreachable
        /// The model server is up but out of capacity (429, used-up accounts).
        case modelBusy
        /// The model server refused Chief's credential (401, 403).
        case modelSignIn
        /// Anything else the harness reported.
        case other
    }

    public var kind: Kind
    /// What Chief said before the turn failed; empty when nothing.
    public var reply: String
    /// The brain's error text, unchanged (diagnostics only).
    public var detail: String

    /// The sentence the conversation shows in place of the raw error.
    public var friendlyText: String {
        switch kind {
        case .modelUnreachable:
            String(localized: "Chief couldn't reach its model, so it didn't finish this.")
        case .modelBusy:
            String(localized: "Chief's model was too busy, so it didn't finish this.")
        case .modelSignIn:
            String(localized: "Chief's model didn't accept its sign-in on your Mac, so it didn't finish this.")
        case .other:
            String(localized: "Chief ran into a problem on your Mac and didn't finish this.")
        }
    }

    /// What Chief's settings say about the model while this is Chief's
    /// newest message; nil when the failure was not the model's.
    public var modelStatus: String? {
        switch kind {
        case .modelUnreachable: String(localized: "Chief's model server isn't reachable right now. Chief's last reply didn't finish.")
        case .modelBusy: String(localized: "Chief's model server is too busy right now. Chief's last reply didn't finish.")
        case .modelSignIn: String(localized: "Chief's model server didn't accept Chief's sign-in on your Mac.")
        case .other: nil
        }
    }

    /// The bar over the conversation while this is Chief's newest message.
    public var barTitle: String {
        switch kind {
        case .modelUnreachable: String(localized: "Chief couldn't reach its model")
        case .modelBusy: String(localized: "Chief's model was too busy")
        case .modelSignIn: String(localized: "Chief's model sign-in failed")
        case .other: String(localized: "Chief didn't finish")
        }
    }

    /// The message as the phone shows it: the reply, then the plain sentence.
    public var displayText: String {
        reply.isEmpty ? friendlyText : "\(reply)\n\n\(friendlyText)"
    }

    init(kind: Kind, reply: String, detail: String) {
        self.kind = kind
        self.reply = reply
        self.detail = detail
    }

    /// The failure at the end of `text`, or nil when Chief's message did
    /// not end in one. Only the brain's own trailing note counts, so a reply
    /// that merely mentions a failure is left alone.
    public init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")") else { return nil }
        // The note starts a line: the whole message, or after a blank line.
        let start: String.Index
        // A turn the brain refused before it ran (`(turn refused: why)`,
        // `ended_turn_text`) is a whole message of its own.
        if trimmed.hasPrefix("(turn failed") || trimmed.hasPrefix("(turn refused") {
            start = trimmed.startIndex
        } else if let range = trimmed.range(of: "\n\n(turn failed", options: .backwards) {
            start = trimmed.index(range.lowerBound, offsetBy: 2)
        } else {
            return nil
        }
        let note = trimmed[start...].dropFirst().dropLast() // without the outer parentheses
        let detail: String
        if note == "turn refused" {
            detail = "refused"
        } else {
            // "turn failed[ on X[ (fallback for Y)]]: error" or "turn refused: why"
            guard let colon = Self.headerColon(in: note) else { return nil }
            detail = String(note[note.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard !detail.isEmpty else { return nil }
        reply = String(trimmed[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = detail
        kind = Self.kind(of: detail)
    }

    /// A list preview of a message that may end in the brain's note. The
    /// Mac's Home list cuts previews short, so the note's closing parenthesis
    /// may be gone: the note is recognized by its start alone here.
    public static func previewText(_ text: String) -> String {
        if let failure = ChiefTurnFailure(text: text) { return failure.displayText }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("(turn failed") || trimmed.hasPrefix("(turn refused") {
            let note = trimmed.dropFirst()
            let detail = note.firstIndex(of: ":").map { String(note[note.index(after: $0)...]) } ?? ""
            return ChiefTurnFailure(kind: kind(of: detail), reply: "", detail: detail).friendlyText
        }
        if let range = trimmed.range(of: "\n\n(turn failed", options: .backwards) {
            let detail = String(trimmed[range.upperBound...])
            let reply = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return ChiefTurnFailure(kind: kind(of: detail), reply: reply, detail: detail).displayText
        }
        return text
    }

    /// `text` without URLs, IP addresses and host:port pairs.
    static func withoutAddresses(_ text: String) -> String {
        var text = text
        for pattern in [#"[a-zA-Z][a-zA-Z0-9+.-]*://\S+"#, #"\b\d{1,3}(\.\d{1,3}){3}(:\d+)?\b"#,
                        #"\b[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)*:\d{2,5}\b"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text
    }

    /// The colon that ends "turn failed[ on X[ (fallback for Y)]]".
    private static func headerColon(in note: Substring) -> Substring.Index? {
        guard let header = ["turn failed", "turn refused"].first(where: { note.hasPrefix($0) }) else { return nil }
        var depth = 0
        var index = note.index(note.startIndex, offsetBy: header.count)
        while index < note.endIndex {
            switch note[index] {
            case "(": depth += 1
            case ")": depth -= 1
            case ":" where depth == 0: return index
            case "\n": return nil
            default: break
            }
            index = note.index(after: index)
        }
        return nil
    }

    /// The kind of a harness error, from what Claude Code, Codex and the
    /// subrouter say. Unknown text is `.other`.
    public static func kind(of detail: String) -> Kind {
        // Addresses first: a port or an IP must not read as a status code.
        let text = withoutAddresses(detail).lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }
        // Capacity before the generic 5xx: the subrouter answers 503 "no
        // non-exhausted ... accounts" when every account is used up.
        if has("429", "rate limit", "rate_limit", "non-exhausted", "usage limit", "quota", "too many requests",
               "529", "overloaded", "at capacity") {
            return .modelBusy
        }
        if has("401", "403", "unauthorized", "forbidden", "authentication", "invalid api key", "invalid x-api-key",
               "oauth", "not logged in", "please run /login", "credential") {
            return .modelSignIn
        }
        if has("api error: 5", "status 5", " 500", " 502", " 503", " 504", "server-side issue",
               "server error", "internal server", "bad gateway", "service unavailable", "gateway timeout",
               "inference gateway", "connection error", "connection refused", "econnrefused", "econnreset",
               "etimedout", "enotfound", "ehostunreach", "fetch failed", "socket hang up", "network", "timed out",
               "timeout", "could not connect", "couldn't connect", "unable to connect", "failed to connect") {
            return .modelUnreachable
        }
        return .other
    }
}

/// Why Chief's settings could not read its engine report (the model
/// picker), keeping apart the cases a person can tell apart: the phone got
/// no answer from the Mac (link down), or the Mac answered and its Chief
/// did not or could not list its models. The model server itself never
/// fails this read (acpmux lists models from its own catalog); its state
/// shows in Chief's turns (``ChiefTurnFailure/modelStatus``).
public enum ChiefEngineProblem: Equatable, Sendable {
    /// The link to the Mac is down or the Mac sent nothing back in time.
    case macUnreachable
    /// The Mac answered, but Chief there did not within the Mac's own 10 s
    /// (its loop was busy, e.g. waiting on acpmux).
    case chiefBusy
    /// Chief answered with an empty model list (acpmux was not connected).
    case modelsUnavailable
    /// The Mac answered, and Chief there is not running or not answering.
    case chiefDown(String)
    /// The Mac explains: Chief not set up, not allowed, a bad value.
    case refused(String)
    /// Something else failed on the Mac.
    case failed

    /// The sentence the settings page shows for a failed load.
    public var loadText: String {
        switch self {
        case .macUnreachable: String(localized: "Your Mac didn't answer. Check that it's on and connected. Trying again…")
        case .chiefBusy: String(localized: "Chief on your Mac is busy and didn't answer in time. Trying again…")
        case .modelsUnavailable: String(localized: "Chief couldn't list its models right now. Trying again…")
        case .chiefDown(let text), .refused(let text): text
        case .failed: String(localized: "Chief on your Mac couldn't load its settings. Try again.")
        }
    }

    /// Whether trying again on its own can help (the settings page retries
    /// with backoff while it is open).
    public var isTransient: Bool {
        switch self {
        case .macUnreachable, .chiefBusy, .modelsUnavailable, .chiefDown, .failed: true
        case .refused: false
        }
    }

    /// The problem behind `error` from a ``ChiefControl`` request.
    public init(_ error: any Error) {
        if error is LinkError {
            self = .macUnreachable
            return
        }
        if let control = error as? ChiefControlError {
            switch (control.code, control.reason) {
            case ("origin.forbidden", _), (_, "not_configured"?), (_, "engine_unavailable"?),
                 ("invalid_avatar", _), (_, "invalid_avatar"?), ("unknown_harness", _), (_, "unknown_harness"?),
                 (_, "invalid_effort"?), (_, "invalid_speed"?):
                self = .refused(control.description)
            // cmux-tui `chief_control.rs`: the daemon waited 10 s for Chief
            // and answered for it (a read timeout), or Chief's tools socket
            // is not there (Chief is not running).
            case (_, "unavailable"?):
                self = Self.isTimeout(control.message) ? .chiefBusy : .chiefDown(control.description)
            default:
                self = .failed
            }
            return
        }
        self = .failed
    }

    /// A socket read that timed out, as Rust's io error text says it on
    /// macOS (`Resource temporarily unavailable (os error 35)`) or Linux.
    static func isTimeout(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["temporarily unavailable", "os error 35", "os error 11", "timed out", "would block", "timeout"]
            .contains { text.contains($0) }
    }

    /// What a successful report says: no models offered means Chief could
    /// not list them (acpmux returns none when its catalog failed).
    public init?(report: ChiefEngineReport) {
        guard report.pickableModels.isEmpty, report.defaultEntry == nil else { return nil }
        self = .modelsUnavailable
    }
}

/// The failed turns of the Chief conversation by message id, each with the
/// brain's raw error text: the conversation shows the plain sentence, and
/// this keeps the detail for the diagnostics view and Try Again.
public final class ChiefFailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String: ChiefTurnFailure] = [:]

    public init() {}

    public func failure(messageID: String) -> ChiefTurnFailure? {
        lock.withLock { failures[messageID] }
    }

    /// Records (or clears: an edited message no longer failed) one message.
    func record(_ failure: ChiefTurnFailure?, messageID: String) {
        lock.withLock { failures[messageID] = failure }
    }
}

/// What the bar over the Chief conversation shows: Chief's open question,
/// else Try Again for Chief's newest turn when it failed.
public enum ChiefBarItem: Equatable, Sendable {
    case question(AgentQuestion)
    /// `id` is the failed message's id.
    case failure(id: String, ChiefTurnFailure)
    /// The Mac's Chief can't be reached: why, and whether Try Again is running.
    case unavailable(reason: String, retrying: Bool)
    /// The Mac is away and Chief reads its cloud copy: messages wait for the
    /// Mac, and the bar offers the Cloud Chief now.
    case macAway(reason: String)
}
