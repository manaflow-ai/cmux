public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// Settings > Agents > Agents with cmux Tools: each coding agent found on this Mac and whether its
/// own config gives it cmux's MCP server, beside the `agents.cmuxMcp` choice row (the onboarding
/// step's question). Add Now is the person's yes: it sets the choice to `on` and runs `cmux setup
/// mcp` for the agents found; Remove runs `cmux setup mcp --remove`, which takes out only cmux's own
/// entry and leaves the choice as it is. Both run only on the person's own click or key in the page.
/// Reading runs `cmux setup mcp --dry-run`, which writes nothing.
@MainActor
final class SettingsAgentTools: PageProvider {
    private let source: any AgentToolsSource
    private var rows: [AgentToolsAgent] = []
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
            "rows": .array(rows.map { ["id": .string($0.id), "name": .string($0.name), "state": .string($0.state.rawValue)] }),
        ]
    }

    /// `refresh` reads (a page may ask); `add` and `remove` change the person's agent configs and run
    /// only on their own click or key (`context.userGesture`) or a call they approved.
    func run(_ params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let action = params["action"]?.stringValue ?? ""
        switch action {
        case "refresh":
            generation += 1
            let mine = generation
            let found = await source.agentToolsAgents()
            guard mine == generation else { return state }
            rows = found
            loaded = true
        case "add", "remove":
            guard context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: "\(action) needs a click in the page")
            }
            guard !applying else { return state }
            applying = true
            generation += 1
            defer { applying = false }
            if action == "add", !(await source.setAgentToolsChoice(.on)) {
                failed = true
                return state
            }
            let result = await source.applyAgentTools(remove: action == "remove")
            if let result { rows = result }
            loaded = true
            failed = result == nil || result?.contains { $0.state == .failed } == true
        default:
            throw PageError.invalidParams("unknown agent tools action \(action)")
        }
        return state
    }
}
