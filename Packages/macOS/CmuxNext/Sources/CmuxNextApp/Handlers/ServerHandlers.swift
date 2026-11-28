import CmuxNextActions
import CmuxNextServer

/// cmux server actions on this Mac (plans/cmux-next/server.md 13). DEV and
/// NIGHTLY: the menu bar item and its panels render the bundled CLI's
/// `server status`; the launch agent registers only in builds that carry the
/// server software and with the `server.agent.allowRegister` Debug Settings
/// switch on, and Stop Serving also reverts the helper's fixes and removes
/// the helper. Scripts use the Rust CLI's `cmux server …` verbs.
enum ServerHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let menuBar = context.services.serverMenuBar
        registry.bind("server.makeThisMacAServer", run: { _ in
            menuBar.show()
            do throws(ServerLaunchAgent.Failure) {
                try ServerLaunchAgent.app().register()
            } catch {
                throw refusal(for: error)
            }
        })
        registry.bind("server.stopServing", run: { _ in
            menuBar.hide()
            registry.track(Task { @MainActor in
                do throws(ServerStopServing.Failure) {
                    try await ServerStopServing.app().run()
                    return nil
                } catch {
                    return ActionWorkFailure(error.message)
                }
            })
        })
        registry.bind("server.showPanel", run: { _ in menuBar.open(.panel(nil)) })
        registry.bind("server.showHealth", run: { _ in menuBar.open(.health(nil)) })
        registry.bind("server.addServer", run: { invocation in
            // No code: the sheet. A code: the same lookup and approve, headless (scripts, a Mac nobody watches).
            guard let code = invocation["code"]?.stringValue, !code.isEmpty else { return menuBar.open(.approver) }
            let services = context.services
            registry.track(Task { @MainActor in
                let source = CloudPairingSource.app(feed: services.feed, auth: services.cloud.auth, chiefPlaced: { [weak services] in services?.home.refreshChiefTab() })
                let reject = await ServerHeadlessApproval.run(source: source, code: code, name: invocation["name"]?.stringValue,
                                                              runChief: invocation["chief"]?.boolValue)
                return reject.map { ActionWorkFailure($0) }
            })
        })
    }

    private static func refusal(for failure: ServerLaunchAgent.Failure) -> ActionFailure {
        switch failure {
        case .notInBuild:
            ActionFailure(message: RefusalStrings.text("refusal.server.notInBuild", "This build does not include the server software yet."))
        case .notReady:
            ActionFailure(message: RefusalStrings.text("refusal.server.notReady", "The server software is not ready in this build yet."))
        case .requiresApproval:
            ActionFailure(message: RefusalStrings.text("refusal.server.needsApproval", "Allow cmux in System Settings > Login Items, then try again."))
        case let .failed(reason):
            ActionFailure(message: RefusalStrings.format("refusal.server.registerFailed", "Could not start the server agent: %@", reason))
        }
    }
}
