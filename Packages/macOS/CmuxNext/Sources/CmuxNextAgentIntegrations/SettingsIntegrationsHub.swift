public import CmuxNextPages
public import CmuxNextSettings
public import Foundation
public import Observation

/// Settings > Integrations: the integrations hub (cmux platform `/v1/hub`), from the bundled
/// `cmux hub overview --json`: linked accounts, waiting approvals, rules, the pause switch and
/// recent audit rows. Linking Stripe or GitHub, removing an account, adding or removing a rule and
/// pausing run `cmux hub ...`, only on the person's click. The CLI owns every request, error and
/// display string (cmux-tui `cli/hub.rs`): this type only relays.
///
/// Answering an approval is the one request made here, not through the CLI: the CLI has no verb
/// for it, because a lane running it holds the person's token and could approve its own agent's
/// refund. The card answers with the person's click, at the platform and team the overview read
/// (`platform`, `team`), for an approval it listed; the shaped call is then read with
/// `cmux hub status`.
///
/// Chief's pinned Needs you section draws the same state as cards (the overview's `approvalCards`,
/// shaped by the CLI): one per waiting approval with Approve and Deny, which answer here as the
/// Settings card does. The card a click answered stays, with what the answer did (`lastAnswer`),
/// until the next refresh; ``changedStream`` tells the page to read the state again.
///
/// The Stripe key the person pastes goes to the CLI's stdin and nowhere else: never an argument,
/// the environment, the state or a log.
///
/// Leo, 2026-11-23: "the executor.sh thing austin was talking ab was he described it as (and you
/// guys ought to look shit up and r&d and we can make an improved thing) an aggregator of
/// integrations. linking up things like e.g. stripe so that your agents can refund for you etc. i
/// assume it's generally ergo ab permissions and whatnot. so we need to make that, but better. and
/// properly working. and have good design for them."
@MainActor
@Observable
public final class SettingsIntegrationsHub: PageProvider {
    public static let stateOp = "cmux.settings.hub.state"
    public static let runOp = "cmux.settings.hub.run"
    /// Fires (no data) after the state changes: a refresh ends, an answer lands.
    public static let changedStream = "cmux.settings.hub.changed"

    /// The CLI's overview, as it printed it (webviews/src/pages/settings/ops.ts `HubOverview`).
    private(set) var overview: JSONValue = .null
    private(set) var loading = false
    /// `unavailable` (no bundled cmux CLI) or `failed` (the overview did not answer).
    private(set) var problem: String?
    /// The last action's refusal, in the CLI's words.
    private(set) var lastError: (action: String, code: String, message: String)?
    /// The last call an answer ran (allow runs the call): its view, for the card's confirmation line.
    private(set) var lastCall: JSONValue = .null
    /// The Chief card the person's click answered: `{approvalId, decision, card}` with the `call` it
    /// ran or the `refused` answer's `{code, message}`, kept through
    /// the refresh the answer runs and dropped on the next one.
    private(set) var lastAnswer: JSONValue = .null

    /// How many Chief cards show: one per waiting approval, the answered one in place of its own.
    public var chiefCards: Int {
        let waiting = (overview["approvalCards"]?.arrayValue ?? []).compactMap { $0["approvalId"]?.stringValue }
        guard let answered = lastAnswer["approvalId"]?.stringValue else { return waiting.count }
        return waiting.filter { $0 != answered }.count + 1
    }

    @ObservationIgnored private let cli: @MainActor () async -> URL?
    @ObservationIgnored private let runCLI: @Sendable (URL, [String], Data?) async throws -> (Int32, Data, Data)
    /// POSTs `body` to `path` at the platform origin with the person's Cloud bearer (and the team
    /// header when one is named): `(status, body)`.
    @ObservationIgnored private let answerApproval: @MainActor (_ platform: URL, _ team: String?, _ path: String, _ body: Data) async throws -> (Int, Data)
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]

    public init(cli: @escaping @MainActor () async -> URL?,
                answerApproval: @escaping @MainActor (URL, String?, String, Data) async throws -> (Int, Data),
                runCLI: @escaping @Sendable (URL, [String], Data?) async throws -> (Int32, Data, Data) = SettingsIntegrationsHub.run) {
        self.cli = cli
        self.answerApproval = answerApproval
        self.runCLI = runCLI
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.stateOp: return state
        case Self.runOp: return try await run(params, context: context)
        default: throw PageError.unknownOp(op)
        }
    }

    /// The page's `cmux.settings.hub.state`.
    var state: JSONValue {
        [
            "loading": .bool(loading),
            "problem": problem.map(JSONValue.string) ?? .null,
            "overview": overview,
            "error": lastError.map { ["action": .string($0.action), "code": .string($0.code), "message": .string($0.message)] } ?? .null,
            "lastCall": lastCall,
            "lastAnswer": lastAnswer,
        ]
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.changedStream else { throw PageError.unknownOp(stream) }
        let id = UUID()
        listeners[id] = onEvent
        return PageSubscription { [weak self] in self?.listeners[id] = nil }
    }

    private func changed() {
        for listener in listeners.values { listener(.object([:])) }
    }

    /// One gesture: `refresh`; `link` with `provider` (`stripe` with `key`, or `github`) and
    /// optional `sharing`; `remove` with a listed
    /// connection `id`; `approve` / `deny` with a waiting approval `id` (approve takes
    /// `remember`); `addRule` with the rule's fields (its action as `ruleAction`, since `action`
    /// is the gesture); `removeRule` with a listed rule `id`; `pause` with `paused`. Only refresh runs without the person's click.
    func run(_ params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let action = params["action"]?.stringValue ?? ""
        if action == "refresh" {
            await refresh(keepAnswer: false)
            return .object([:])
        }
        guard context.userGesture || context.isConfirmedUser else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: "\(action) needs a click in the page")
        }
        if action == "approve" || action == "deny" { return try await answer(action, params: params) }
        let words = try Self.arguments(action: action, params: params, overview: overview)
        let stripe = action == "link" && words.contains("stripe")
        let stdin: Data? = stripe ? Self.keyData(params) : nil
        if stripe, stdin == nil { throw PageError.invalidParams("paste a restricted key") }
        guard let cli = await cli() else { throw PageError(code: "cmux.page.unavailable", message: "no bundled cmux CLI") }
        let reply = try? await runCLI(cli, ["hub"] + words + ["--json"], stdin)
        let answer = reply.flatMap { Self.lastLine($0.1) }
        if let answer, answer["ok"]?.boolValue == true {
            lastError = nil
            lastCall = answer["call"] ?? .null
        } else {
            lastError = (action,
                         answer?["error"]?["code"]?.stringValue ?? "cli.failed",
                         answer?["error"]?["message"]?.stringValue ?? "")
            lastCall = answer?["call"] ?? .null
        }
        await refresh()
        return answer ?? .object([:])
    }

    /// Answers a listed approval on the person's click: `{decision, remember?}` to the hub, then
    /// the call as the CLI shapes it.
    func answer(_ action: String, params: JSONValue) async throws -> JSONValue {
        let id = params["id"]?.stringValue ?? ""
        let request = try Self.answerRequest(action: action, params: params, overview: overview)
        let card = (overview["approvalCards"]?.arrayValue ?? []).first { $0["approvalId"]?.stringValue == id } ?? .null
        let reply: (Int, Data)?
        do { reply = try await answerApproval(request.platform, request.team, request.path, request.body) } catch { reply = nil }
        let value = reply.flatMap { try? JSONValue.parse($0.1) }
        if let reply, (200..<300).contains(reply.0) {
            lastError = nil
            lastCall = .null
            // The call the answer ran (allow runs it), shaped by the CLI for the confirmation line.
            if let callID = value?["call"]?["id"]?.stringValue ?? Self.callID(overview, approval: id), let cli = await cli(),
               let shaped = try? await runCLI(cli, ["hub", "status", callID, "--json"], nil), let call = Self.lastLine(shaped.1)?["call"] {
                lastCall = call
            }
        } else {
            lastError = (action,
                         value?["error"]?["code"]?.stringValue ?? (reply == nil ? "api.unreachable" : "api.bad_answer"),
                         value?["error"]?["message"]?.stringValue ?? "")
        }
        // An answer that landed keeps its card with what it did; a refused one keeps it waiting, with the refusal.
        if card == .null {
            lastAnswer = .null
        } else if let refused = lastError {
            lastAnswer = ["approvalId": .string(id), "decision": .string(action), "card": card,
                          "refused": ["code": .string(refused.code), "message": .string(refused.message)]]
        } else {
            lastAnswer = ["approvalId": .string(id), "decision": .string(action), "card": card, "call": lastCall]
        }
        await refresh(keepAnswer: true)
        return ["ok": .bool(lastError == nil)]
    }

    /// Where and what an answer sends: only for an approval the overview listed, only to the
    /// https platform it read.
    nonisolated static func answerRequest(action: String, params: JSONValue, overview: JSONValue) throws
        -> (platform: URL, team: String?, path: String, body: Data) {
        let id = params["id"]?.stringValue ?? ""
        guard listed(overview, "approvals", key: "approvalId").contains(id),
              id.hasPrefix("apr_"), id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            throw PageError.invalidParams("id must be a waiting approval")
        }
        guard let origin = overview["platform"]?.stringValue, let platform = URL(string: origin), platform.scheme == "https" else {
            throw PageError(code: "cmux.page.unavailable", message: "the overview named no platform")
        }
        var body: [String: JSONValue] = ["decision": .string(action == "approve" ? "allow" : "deny")]
        if action == "approve", params["remember"]?.boolValue == true { body["remember"] = .bool(true) }
        return (platform, overview["team"]?.stringValue, "v1/hub/approvals/\(id)/answer", Data(JSONValue.object(body).compactText.utf8))
    }

    /// The call a listed approval belongs to.
    nonisolated static func callID(_ overview: JSONValue, approval: String) -> String? {
        (overview["approvals"]?.arrayValue ?? []).first { $0["approvalId"]?.stringValue == approval }?["id"]?.stringValue
    }

    /// The key as the CLI's stdin, trimmed; nil when empty or too long to be a key.
    nonisolated static func keyData(_ params: JSONValue) -> Data? {
        guard let key = params["key"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty, key.utf8.count <= 256 else { return nil }
        return Data(key.utf8)
    }

    /// The ids the overview listed under `list` (`id`, or `approvalId` for approvals).
    nonisolated static func listed(_ overview: JSONValue, _ list: String, key: String = "id") -> Set<String> {
        Set((overview[list]?.arrayValue ?? []).compactMap { $0[key]?.stringValue })
    }

    /// The CLI words (after `hub`) for one action. Every id is one the card was shown, and a rule
    /// takes only the fields the CLI knows, so a page script cannot pass flags of its own.
    nonisolated static func arguments(action: String, params: JSONValue, overview: JSONValue) throws -> [String] {
        let id = params["id"]?.stringValue ?? ""
        switch action {
        case "link":
            let provider = params["provider"]?.stringValue ?? "stripe"
            guard provider == "stripe" || provider == "github" else { throw PageError.invalidParams("provider is stripe or github") }
            var words = ["link", provider]
            if let sharing = params["sharing"]?.stringValue {
                guard sharing == "private" || sharing == "team" else { throw PageError.invalidParams("sharing is private or team") }
                words += ["--sharing", sharing]
            }
            return words
        case "remove":
            guard listed(overview, "connections").contains(id) else { throw PageError.invalidParams("id must be a listed account") }
            return ["remove", id]
        case "removeRule":
            guard listed(overview, "rules").contains(id) else { throw PageError.invalidParams("id must be a listed rule") }
            return ["rule", "remove", id]
        case "pause":
            return [params["paused"]?.boolValue == true ? "pause" : "resume"]
        case "addRule":
            var words = ["rule", "add"]
            let fields: [(String, String)] = [
                ("ruleAction", "--action"), ("effect", "--effect"), ("owner", "--owner"), ("connection", "--connection"),
                ("agent", "--agent"), ("amountLte", "--amount-lte"), ("amountGt", "--amount-gt"), ("currency", "--currency"),
                ("repo", "--repo"), ("limitWindow", "--limit-window"), ("limitAmount", "--limit-amount"),
                ("limitCalls", "--limit-calls"), ("limitOver", "--limit-over"),
            ]
            for (key, flag) in fields {
                let value: String? = params[key]?.stringValue ?? params[key]?.doubleValue.map { String(Int64($0)) }
                guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { continue }
                // A value is never read as a flag: the CLI takes `--flag=value` whole.
                words.append("\(flag)=\(value)")
            }
            return words
        default:
            throw PageError.invalidParams("unknown action \(action)")
        }
    }

    /// The CLI prints one JSON object, on its last line.
    nonisolated static func lastLine(_ data: Data) -> JSONValue? {
        let last = String(data: data, encoding: .utf8)?.split(separator: "\n").last.map { Data($0.utf8) } ?? Data()
        return try? JSONValue.parse(last)
    }

    /// Reads the overview again; only the newest read writes it. A refresh an answer did not run
    /// drops the answered Chief card (`keepAnswer` false).
    public func refresh(keepAnswer: Bool = false) async {
        if !keepAnswer { lastAnswer = .null }
        defer { changed() }
        guard let cli = await cli() else {
            overview = .null
            problem = "unavailable"
            return
        }
        generation += 1
        let mine = generation
        loading = true
        let reply = try? await runCLI(cli, ["hub", "overview", "--json"], nil)
        guard mine == generation else { return }
        loading = false
        guard let reply, let value = Self.lastLine(reply.1) else {
            problem = "failed"
            return
        }
        if value["ok"]?.boolValue == true {
            overview = value
            problem = nil
        } else {
            // A refusal (signed out, no team access) is the CLI's error object; the card shows it.
            overview = value
            problem = "failed"
        }
    }
}
