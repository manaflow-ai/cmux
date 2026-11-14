public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// Settings > Agents > cmux Tools for Agents in cmux: each coding agent found on this Mac and
/// whether it gets cmux's MCP server when cmux starts it, beside the `agents.cmuxMcp` choice row
/// (the onboarding step's question), and the manual lines a person runs themselves to use cmux's
/// tools in agents started elsewhere (`cmux setup mcp`'s `manual`; cmux never runs them). Turn On is
/// the person's yes: it sets the choice to `on`, only on their own click or key in the page.
/// Reading runs `cmux setup mcp`, which writes nothing.
@MainActor
final class SettingsAgentTools: PageProvider {
    private let source: any AgentToolsSource
    private var rows: [AgentToolsAgent] = []
    private var manual: [String] = []
    private var loaded = false
    private var applying = false
    private var failed = false
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
            "rows": .array(rows.map { ["id": .string($0.id), "name": .string($0.name), "state": .string($0.state.rawValue)] }),
            "manual": .array(manual.map { .string($0) }),
        ]
    }

    /// `refresh` reads (a page may ask); `turnOn` writes the person's answer and runs only on their
    /// own click or key (`context.userGesture`) or a call they approved.
    func run(_ params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let action = params["action"]?.stringValue ?? ""
        switch action {
        case "refresh":
            await read()
        case "turnOn":
            guard context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: "\(action) needs a click in the page")
            }
            guard !applying else { return state }
            applying = true
            defer { applying = false }
            failed = !(await source.setAgentToolsChoice(.on))
            await read()
        default:
            throw PageError.invalidParams("unknown agent tools action \(action)")
        }
        return state
    }

    /// Reads the agents and the manual lines; only the newest read lands.
    private func read() async {
        generation += 1
        let mine = generation
        async let found = source.agentToolsAgents()
        async let lines = source.agentToolsManualCommands()
        let (agents, commands) = await (found, lines)
        guard mine == generation else { return }
        rows = agents
        manual = commands
        loaded = true
    }
}
