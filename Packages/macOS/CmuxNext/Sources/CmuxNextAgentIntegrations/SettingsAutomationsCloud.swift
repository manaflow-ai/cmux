public import CmuxNextPages
public import CmuxNextSettings
public import Foundation
public import Observation

/// Settings > Automations: Cloud automations (cmux platform `/v1/automations`), from the bundled
/// `cmux autocloud overview --json`: each automation with its trigger, conditions, agent and last
/// run, the template gallery and the pickers' choices. Creating, editing, switching on or off and
/// removing run `cmux autocloud ...`, only on the person's click; reading a run log and previewing
/// a prompt against a sample event need none. The CLI owns every request, check and display string
/// (cmux-tui `cli/autocloud.rs`): this type only relays.
///
/// A spec goes to the CLI's stdin, never an argument. A new webhook automation's secret is in the
/// create answer the card reads once; it is never kept in the state, a log or the page's storage.
///
/// Leo, 2026-11-24: "likewise, setting up automation and webhooks will be ultra big for us; having
/// people be able to set up their own conditions for when autocloud will go off, and examining and
/// perfecting our github integrations all the way through and through"
@MainActor
@Observable
public final class SettingsAutomationsCloud: PageProvider {
    public static let stateOp = "cmux.settings.autocloud.state"
    public static let runOp = "cmux.settings.autocloud.run"

    /// The CLI's overview, as it printed it (webviews/src/pages/settings/ops.ts `AutocloudOverview`).
    private(set) var overview: JSONValue = .null
    private(set) var loading = false
    /// `unavailable` (no bundled cmux CLI) or `failed` (the overview did not answer).
    private(set) var problem: String?
    /// The last action's refusal, in the CLI's words.
    private(set) var lastError: (action: String, code: String, message: String)?

    @ObservationIgnored private let cli: @MainActor () async -> URL?
    @ObservationIgnored private let runCLI: @Sendable (URL, [String], Data?) async throws -> (Int32, Data, Data)
    @ObservationIgnored private var generation = 0

    /// The largest spec or preview the card sends, in bytes.
    nonisolated static let maxInput = 64 * 1024

    public init(cli: @escaping @MainActor () async -> URL?,
                runCLI: @escaping @Sendable (URL, [String], Data?) async throws -> (Int32, Data, Data) = SettingsAutomationsCloud.run) {
        self.cli = cli
        self.runCLI = runCLI
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.stateOp: return state
        case Self.runOp: return try await run(params, context: context)
        default: throw PageError.unknownOp(op)
        }
    }

    /// The page's `cmux.settings.autocloud.state`.
    var state: JSONValue {
        [
            "loading": .bool(loading),
            "problem": problem.map(JSONValue.string) ?? .null,
            "overview": overview,
            "error": lastError.map { ["action": .string($0.action), "code": .string($0.code), "message": .string($0.message)] } ?? .null,
        ]
    }

    /// One action: `refresh`; `preview` with `spec` and `sample` or `event`; `runs` with a listed
    /// `id`; and on a click only, `create` with `spec`, `update` with a listed `id` and `spec`,
    /// `toggle` with a listed `id` and `enabled`, `remove` with a listed `id`. Returns the CLI's answer.
    func run(_ params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let action = params["action"]?.stringValue ?? ""
        if action == "refresh" {
            await refresh()
            return state
        }
        let request = try Self.request(action: action, params: params, overview: overview)
        if request.needsClick, !(context.userGesture || context.isConfirmedUser) {
            throw PageError(code: PageNativeOp.userOnlyCode, message: "\(action) needs a click in the page")
        }
        guard let cli = await cli() else { throw PageError(code: "cmux.page.unavailable", message: "no bundled cmux CLI") }
        let reply = try? await runCLI(cli, ["autocloud"] + request.words + ["--json"], request.stdin)
        let answer = reply.flatMap { Self.lastLine($0.1) } ?? [
            "ok": .bool(false), "error": ["code": .string("cli.failed"), "message": .string("")],
        ]
        guard request.needsClick else { return answer }
        if answer["ok"]?.boolValue == true {
            lastError = nil
        } else {
            lastError = (action, answer["error"]?["code"]?.stringValue ?? "cli.failed",
                         answer["error"]?["message"]?.stringValue ?? "")
        }
        await refresh()
        return answer
    }

    /// The CLI words (after `autocloud`) and stdin for one action. Every id is one the overview
    /// listed and a revision is the one it read, so a page script cannot pass flags of its own.
    nonisolated static func request(action: String, params: JSONValue, overview: JSONValue) throws
        -> (words: [String], stdin: Data?, needsClick: Bool) {
        let id = params["id"]?.stringValue ?? ""
        let listedAutomation = (overview["automations"]?.arrayValue ?? []).first { $0["id"]?.stringValue == id }
        func listed() throws -> JSONValue {
            guard let listedAutomation else { throw PageError.invalidParams("id must be a listed automation") }
            return listedAutomation
        }
        func body(_ value: JSONValue) throws -> Data {
            let data = Data(value.compactText.utf8)
            guard data.count <= maxInput else { throw PageError.invalidParams("the automation is too long") }
            return data
        }
        func spec() throws -> JSONValue {
            guard let spec = params["spec"], case .object = spec else { throw PageError.invalidParams("spec must be an object") }
            return spec
        }
        switch action {
        case "preview":
            var input: [String: JSONValue] = ["spec": try spec()]
            if let sample = params["sample"]?.stringValue { input["sample"] = .string(sample) }
            if let event = params["event"], case .object = event { input["event"] = event }
            return (["preview"], try body(.object(input)), false)
        case "runs":
            _ = try listed()
            return (["runs", id, "--limit=50"], nil, false)
        case "create":
            return (["create"], try body(try spec()), true)
        case "update":
            let automation = try listed()
            guard case .object(var fields) = try spec() else { throw PageError.invalidParams("spec must be an object") }
            // The revision the overview read: an edit made elsewhere since is the platform's conflict.
            fields["revision"] = automation["revision"] ?? .null
            return (["update", id], try body(.object(fields)), true)
        case "toggle":
            let automation = try listed()
            guard let enabled = params["enabled"]?.boolValue else { throw PageError.invalidParams("enabled must be true or false") }
            let revision = Int64(automation["revision"]?.doubleValue ?? 0)
            return ([enabled ? "enable" : "disable", id, "--revision=\(revision)"], nil, true)
        case "remove":
            _ = try listed()
            return (["remove", id], nil, true)
        default:
            throw PageError.invalidParams("unknown action \(action)")
        }
    }

    /// The CLI prints one JSON object, on its last line.
    nonisolated static func lastLine(_ data: Data) -> JSONValue? {
        let last = String(data: data, encoding: .utf8)?.split(separator: "\n").last.map { Data($0.utf8) } ?? Data()
        return try? JSONValue.parse(last)
    }

    /// Reads the overview again; only the newest read writes it.
    public func refresh() async {
        guard let cli = await cli() else {
            overview = .null
            problem = "unavailable"
            return
        }
        generation += 1
        let mine = generation
        loading = true
        let reply = try? await runCLI(cli, ["autocloud", "overview", "--json"], nil)
        guard mine == generation else { return }
        loading = false
        guard let reply, let value = Self.lastLine(reply.1) else {
            problem = "failed"
            return
        }
        // A refusal (signed out, no team access) is the CLI's error object; the card shows it.
        overview = value
        problem = value["ok"]?.boolValue == true ? nil : "failed"
    }
}
