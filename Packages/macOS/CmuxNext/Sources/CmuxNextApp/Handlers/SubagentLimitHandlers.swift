import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextSettings

/// Subagent Limit… (``SubagentLimit``) on a chat tab and its sidebar row; the palette runs it on
/// the focused chat. The row is left out of other tabs' menus.
enum SubagentLimitHandlers {
    static let chatAction: ActionID = "agentChat.subagentLimit"

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        let flow = { (window: NSWindow?) in
            SubagentLimitFlow(
                open: { [weak services] in
                    guard let services, let environment = QuitAgents.environment(services) else { return nil }
                    return await AcpmuxPersonLine.open(environment)
                },
                present: { spec in await CmuxDialogCenter.shared.present(spec, in: window.map { .window($0) } ?? .app) },
                setting: { [weak services] in
                    Int(services?.settings?.snapshot.subsessions.maxRunning ?? SubsessionSettings.subsessionsMaxRunningDefault)
                })
        }
        /// The targeted tab's acpmux session, when it is a chat of this Mac's acpmux.
        let chat = { (invocation: ActionInvocation) -> String? in
            guard let ref = context.daemonTab(invocation)?.tab.agentSession, let session = ref.session,
                  ref.host == services.agentTabs.localHost else { return nil }
            return session
        }
        registry.bind(chatAction, run: { invocation in
            guard let session = chat(invocation) else { throw ActionFailure(message: SubagentLimitStrings.notAChat) }
            let run = flow(context.activeWindow?.window)
            context.report { await run.run(.chat(session)) }
        })
        ActionTargetVisibility.hide(chatAction, in: registry) { invocation in
            invocation.target?.kind == .tab && registry.withoutRefusals { chat(invocation) } == nil
        }
    }
}

/// One run of the dialog: read the current limit, ask, send the change. Each request opens its
/// own short person connection (``AcpmuxPersonLine`` lives a few seconds, the dialog longer).
@MainActor
struct SubagentLimitFlow {
    /// A connection to this Mac's acpmux proven as the person; nil when none answers.
    let open: @MainActor () async -> (any AgentDialogLine)?
    let present: @MainActor (CmuxDialogSpec) async -> CmuxDialogAnswer
    /// `agents.subsessions.maxRunning`.
    let setting: @MainActor () -> Int

    /// Nil when it was set, cleared or cancelled; else why not. A read that gets no answer (no
    /// acpmux, a connection acpmux did not take as the person, a refusal) says it could not be
    /// read; only an answer without `maxRunning` says this acpmux has no limit.
    func run(_ scope: SubagentLimit.Scope) async -> ActionWorkFailure? {
        guard let reply = await call(scope.params(nil)) else { return ActionWorkFailure(SubagentLimitStrings.unreadable) }
        guard let current = SubagentLimit.Current(reply: reply, scope: scope) else {
            return ActionWorkFailure(SubagentLimitStrings.unsupported)
        }
        let prompt = SubagentLimit(scope: scope, current: current, setting: setting())
        switch SubagentLimit.change(for: await present(prompt.spec)) {
        case nil: return nil
        case .failure: return ActionWorkFailure(SubagentLimitStrings.invalid)
        case .success(let change):
            return await call(scope.params(change)) == nil ? ActionWorkFailure(SubagentLimitStrings.failed) : nil
        }
    }

    /// The request's result; nil when no acpmux answered, it refused the person proof, or it
    /// refused the request.
    private func call(_ params: [String: Any]) async -> [String: Any]? {
        guard let line = await open() else { return nil }
        defer { line.close() }
        guard line.isPerson else { return nil }
        return await line.call(SubagentLimit.method, params)
    }
}
