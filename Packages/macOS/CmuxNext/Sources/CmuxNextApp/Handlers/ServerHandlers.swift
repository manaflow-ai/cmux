import CmuxNextActions
import CmuxNextServer
import CmuxNextWakeups

/// cmux server actions on this Mac (plans/cmux-next/server.md 13). DEV and
/// NIGHTLY: the menu bar item and its panels render the bundled CLI's
/// `server status`; the launch agent registers only in builds that carry the
/// server software and with the `server.agent.allowRegister` Debug Settings
/// switch on, and Stop Serving also reverts the helper's fixes and removes
/// the helper. Scripts use the Rust CLI's `cmux server …` verbs.
enum ServerHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let menuBar = context.services.serverMenuBar
        registry.bindEffect("server.makeThisMacAServer", effect: { _ in
            // The item shows on this turn; the agent's launchd calls run on the system lane.
            menuBar.show()
            let agent = ServerLaunchAgent.app(work: context.services.work)
            return .applied(ActionConfirmation(send: {
                do throws(ServerLaunchAgent.Failure) {
                    try await agent.register()
                    return nil
                } catch {
                    return ActionWorkFailure(refusal: .unavailable, reason: refusal(for: error))
                }
            }))
        })
        let services = context.services
        let mainWork = services.mainWork
        registry.bind("server.stopServing", run: { invocation in
            menuBar.hide()
            // The reverts and the unregisters are awaited off main; the failure is the run's, in one task on main.
            registry.trackWork(owner: "ServerHandlers.stopServing", on: mainWork) {
                try await stopServing(work: services.work)
            } then: { result in
                guard case .failure(let error) = result else { return nil }
                return ActionWorkFailure((error as? ServerStopServing.Failure)?.message ?? String(describing: error))
            }
        })
        registry.bind("server.showPanel", run: { _ in menuBar.open(.panel(nil)) })
        registry.bind("server.showHealth", run: { _ in menuBar.open(.health(nil)) })
        registry.bind("server.addServer", run: { invocation in
            // No code: the sheet. A code may come only from an in-process person action; the
            // descriptor's person-only gate refuses every CLI, MCP, script, page and remote run.
            guard let code = invocation["code"]?.stringValue, !code.isEmpty else { return menuBar.open(.approver) }
            guard ServerHeadlessApproval.allows(origin: invocation.origin) else {
                throw ActionFailure(message: ServerHeadlessApproval.notFromThisMac)
            }
            // The pairing's cloud calls are awaited off main; the refusal is the run's, in one task on main.
            registry.trackWork(owner: "ServerHandlers.addServer", on: mainWork) {
                await approve(code: code, invocation, services)
            } then: { result in
                guard case .success(let reject?) = result else { return nil }
                return ActionWorkFailure(reject)
            }
        })
    }

    /// Stop Serving on this Mac (`ServerStopServing`).
    private static func stopServing(work: BackgroundWork) async throws(ServerStopServing.Failure) {
        try await ServerStopServing.app(work: work).run()
    }

    /// A headless Add Server approval of pairing `code`; nil when approved, else why not.
    private static func approve(code: String, _ invocation: ActionInvocation, _ services: AppServices) async -> String? {
        let source = CloudPairingSource.app(feed: services.feed, auth: services.cloud.auth, work: services.work, mainWork: services.mainWork, chiefPlaced: { [weak services] in services?.home.refreshChiefTab() })
        return await ServerHeadlessApproval.run(source: source, code: code, words: invocation["words"]?.stringValue,
                                                name: invocation["name"]?.stringValue, runChief: invocation["chief"]?.boolValue)
    }

    private static func refusal(for failure: ServerLaunchAgent.Failure) -> String {
        switch failure {
        case .notInBuild:
            RefusalStrings.text("refusal.server.notInBuild", "This build does not include the server software yet.")
        case .notReady:
            RefusalStrings.text("refusal.server.notReady", "The server software is not ready in this build yet.")
        case .requiresApproval:
            RefusalStrings.text("refusal.server.needsApproval", "Allow cmux in System Settings > Login Items, then try again.")
        case let .failed(reason):
            RefusalStrings.format("refusal.server.registerFailed", "Could not start the server agent: %@", reason)
        }
    }
}
