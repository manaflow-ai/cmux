public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// Settings > Agents > Give Agents cmux’s Tools: each coding agent found on this Mac and
/// whether it gets cmux's MCP server when cmux starts it, beside the `agents.cmuxMcp` choice row
/// (on by default), and the manual lines a person runs themselves to use cmux's tools in agents
/// started elsewhere (`cmux setup mcp`'s `manual`; cmux never runs them). Turn On (shown once the
/// person turned the row off) sets the choice back to `on`. Remove takes out a `cmux` entry in an agent's own
/// config that runs `cmux mcp serve`, used outside cmux (`cmux setup mcp --remove ID`); when cmux
/// keeps it (settings it could not put back), the card shows the CLI's reason (`note`). Both run
/// only on the person's own click or key in the page. Reading runs `cmux setup mcp` once, which
/// writes nothing.
@MainActor
final class SettingsAgentTools: PageProvider {
    private let source: any AgentToolsSource
    private var rows: [AgentToolsAgent] = []
    private var manual: [String] = []
    private var loaded = false
    private var applying = false
    private var failed = false
    /// Why the last Remove kept the entry (the CLI's `user_action.text`), until the next gesture.
    private var note: String?
    private var generation = 0

    init(source: any AgentToolsSource) {
        self.source = source
    }

    /// `cmux.settings.agentTools.state` and `.run`; any other op is not this card's.
    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case "cmux.settings.agentTools.state": return state
        case "cmux.settings.agentTools.run": return try await run(params, context: context)
        default: throw PageError.unknownOp(op)
        }
    }

    /// The page's `AgentToolsCardState` (webviews/src/pages/settings/ops.ts).
    var state: JSONValue {
        [
            "loaded": .bool(loaded), "applying": .bool(applying), "failed": .bool(failed),
            "choice": .string(source.agentToolsChoice().rawValue),
            "rows": .array(rows.map {
                ["id": .string($0.id), "name": .string($0.name), "state": .string($0.state.rawValue),
                 "leftover": $0.leftover.map(JSONValue.string) ?? .null]
            }),
            "manual": .array(manual.map { .string($0) }),
            "note": note.map(JSONValue.string) ?? .null,
        ]
    }

    /// `refresh` reads (a page may ask); `turnOn` writes the person's answer and `removeLeftover`
    /// (`id`) takes out an agent's old `cmux` entry, each only on their own click or key
    /// (`context.userGesture`) or a call they approved.
    func run(_ params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let action = params["action"]?.stringValue ?? ""
        switch action {
        case "refresh":
            await read()
        case "removeLeftover":
            guard context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: "\(action) needs a click in the page")
            }
            guard let id = params["id"]?.stringValue, rows.contains(where: { $0.id == id && $0.leftover != nil }) else {
                throw PageError.invalidParams("no cmux entry to remove for that agent")
            }
            guard !applying else { return state }
            applying = true
            defer { applying = false }
            switch await source.removeLeftoverEntry(id) {
            case .removed: (failed, note) = (false, nil)
            case .kept(let why): (failed, note) = (false, why)
            case .failed: (failed, note) = (true, nil)
            }
            await read()
        case "turnOn":
            guard context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: "\(action) needs a click in the page")
            }
            guard !applying else { return state }
            applying = true
            defer { applying = false }
            failed = !(await source.setAgentToolsChoice(.on))
            note = nil
            await read()
        default:
            throw PageError.invalidParams("unknown agent tools action \(action)")
        }
        return state
    }

    /// Reads the agents and the manual lines, one `cmux setup mcp` run; only the newest read lands.
    private func read() async {
        generation += 1
        let mine = generation
        let report = await source.agentToolsReport()
        guard mine == generation else { return }
        rows = report?.agents ?? []
        manual = report?.manual ?? []
        loaded = true
    }
}
