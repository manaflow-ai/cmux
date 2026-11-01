public import CmuxNextPages
public import CmuxNextSettings
public import Foundation
public import Observation

/// Settings > Agents > Agent integrations: optional help for the coding-agent hooks that report an
/// agent's state to cmux. The rows are the bundled CLI's `cmux --json agent hook status`; Install
/// and Repair run `agent hook install <id>`, Remove runs `agent hook uninstall <id>`, then status
/// is read again. The CLI owns every file write and its refusals (a symlink, a non-file, a plugin
/// file cmux did not write), so this type only reads and relays: a row in `conflict` offers no
/// Install, and the page shows the CLI's own command for doing it by hand. Nothing runs until the
/// page asks: the card reads status when it is shown, and writes only on a click. The App
/// supplies the bundled CLI's location and routes the page's `cmux.settings.integrations.*` here.
@MainActor
@Observable
public final class SettingsAgentIntegrations: PageProvider {
    /// One provider as `agent hook status` reports it (cmux-tui-hooks `run_with_context`).
    struct Row: Equatable {
        var id: String
        var path: String
        /// `installed`, `partial`, `absent`, `conflict` or `unavailable`.
        var state: String
        /// For `conflict` / `unavailable`: `symlink`, `not_a_file`, `not_a_directory`, `not_owned`, `unreadable`.
        var reason: String?
        /// The CLI's own (English) text for a conflict.
        var detail: String?
        /// The CLI's refusal of this row's last gesture, in the CLI's own words.
        var error: String?
        /// When the CLI gave no words of its own: `noAnswer` (it did not run or answer) or
        /// `notFinished` (it failed without saying why). The page shows its localized text.
        var errorKind: String?
    }

    /// A refused gesture: the CLI's own text, or a kind the page localizes.
    enum Refusal: Equatable {
        case text(String)
        case kind(String)
    }

    /// The command a person can run in a terminal instead (each row appends its id).
    static let manualCommand = "cmux agent hook install"

    private(set) var rows: [Row] = []
    private(set) var loading = false
    /// `unavailable` (this build carries no CLI) or `failed` (status did not answer).
    private(set) var problem: String?
    @ObservationIgnored private let cli: @MainActor () async -> URL?
    @ObservationIgnored private let runCLI: @Sendable (URL, [String]) async throws -> (Int32, Data, Data)
    @ObservationIgnored private var generation = 0

    public init(cli: @escaping @MainActor () async -> URL?,
                runCLI: @escaping @Sendable (URL, [String]) async throws -> (Int32, Data, Data) = SettingsAgentIntegrations.run) {
        self.cli = cli
        self.runCLI = runCLI
    }

    /// `cmux.settings.integrations.state` and `.run`; any other op is not this card's.
    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case "cmux.settings.integrations.state": return state
        case "cmux.settings.integrations.run": return try await run(params, context: context)
        default: throw PageError.unknownOp(op)
        }
    }

    /// The page's `cmux.settings.integrations.state` (webviews/src/pages/settings/ops.ts `IntegrationsState`).
    var state: JSONValue {
        [
            "loading": .bool(loading),
            "problem": problem.map(JSONValue.string) ?? .null,
            "command": .string(Self.manualCommand),
            "providers": .array(rows.map { row in
                [
                    "id": .string(row.id), "path": .string(row.path), "state": .string(row.state),
                    "reason": row.reason.map(JSONValue.string) ?? .null,
                    "detail": row.detail.map(JSONValue.string) ?? .null,
                    "error": row.error.map(JSONValue.string) ?? .null,
                    "errorKind": row.errorKind.map(JSONValue.string) ?? .null,
                ]
            }),
        ]
    }

    /// One page gesture (`cmux.settings.integrations.run`): `refresh`, or `install` / `repair` /
    /// `remove` with a listed provider `id`. Refresh only reads, so a page may ask for it; the
    /// others change the person's agent configs and run only on the person's own click or key
    /// in the page (`context.userGesture`, the host's record) or a call they approved, as the
    /// Harnesses card's updates do: a page script alone gets `cmux.app.user_only`.
    func run(_ params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let action = params["action"]?.stringValue ?? ""
        switch action {
        case "refresh":
            await refresh()
        case "install", "repair", "remove":
            guard context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: "\(action) needs a click in the page")
            }
            guard let id = params["id"]?.stringValue, let row = rows.first(where: { $0.id == id }) else {
                throw PageError.invalidParams("id must be a listed provider")
            }
            // The CLI would refuse it too; the page never offers it.
            if action != "remove", row.state == "conflict" || row.state == "unavailable" {
                throw PageError.invalidParams("\(id) has a file cmux did not create in the way")
            }
            guard let cli = await cli() else { throw PageError(code: "cmux.page.unavailable", message: "no cmux CLI") }
            let verb = action == "remove" ? "uninstall" : "install"
            let reply = try? await runCLI(cli, ["--json", "agent", "hook", verb, id])
            let refusal = reply.map { Self.refusal(of: id, $0) } ?? .kind("noAnswer")
            await refresh()
            if let refusal, let index = rows.firstIndex(where: { $0.id == id }) {
                switch refusal {
                case .text(let text): rows[index].error = text
                case .kind(let kind): rows[index].errorKind = kind
                }
            }
        default:
            throw PageError.invalidParams("unknown integrations action \(action)")
        }
        return .object([:])
    }

    /// Reads `agent hook status` again; only the newest read writes the rows.
    func refresh() async {
        guard let cli = await cli() else {
            rows = []
            problem = "unavailable"
            return
        }
        generation += 1
        let mine = generation
        loading = true
        let reply = try? await runCLI(cli, ["--json", "agent", "hook", "status"])
        guard mine == generation else { return }
        loading = false
        // A provider status could not read (invalid JSON) fails the command, with the rows it did
        // read in the error's details.
        guard let reply, let read = Self.rows(reply.0 == 0 ? reply.1 : reply.2) else {
            problem = "failed"
            return
        }
        rows = read
        problem = nil
    }

    /// The `providers` of a status answer (stdout) or of a failure's `details` (stderr).
    static func rows(_ data: Data) -> [Row]? {
        guard let value = try? JSONValue.parse(data) else { return nil }
        let body = value["details"] ?? value
        guard let providers = body["providers"]?.arrayValue else { return nil }
        var rows: [Row] = providers.compactMap { item in
            guard let id = item["provider"]?.stringValue, let state = item["state"]?.stringValue else { return nil }
            return Row(id: id, path: item["path"]?.stringValue ?? "", state: state,
                       reason: item["reason"]?.stringValue, detail: item["detail"]?.stringValue)
        }
        // `<id>: <message>` for a provider status could not read: shown on a row of its own.
        for error in body["errors"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            guard let split = error.range(of: ": ") else { continue }
            let id = String(error[..<split.lowerBound])
            guard !rows.contains(where: { $0.id == id }), !id.contains(" ") else { continue }
            rows.append(Row(id: id, path: "", state: "unavailable", reason: "unreadable",
                            detail: String(error[split.upperBound...])))
        }
        return rows
    }

    /// The CLI's refusal of a gesture on `id`, from a failed run's stderr; nil when it succeeded.
    static func refusal(of id: String, _ reply: (Int32, Data, Data)) -> Refusal? {
        guard reply.0 != 0 else { return nil }
        let errors = (try? JSONValue.parse(reply.2))?["details"]?["errors"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let own = errors.first(where: { $0.hasPrefix("\(id): ") }) { return .text(String(own.dropFirst(id.count + 2))) }
        if let first = errors.first { return .text(first) }
        let text = String(data: reply.2, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? .kind("notFinished") : .text(text)
    }
}
