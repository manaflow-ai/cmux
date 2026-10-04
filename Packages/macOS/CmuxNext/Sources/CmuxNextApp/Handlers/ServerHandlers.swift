import CmuxNextActions
import CmuxNextServer

/// cmux server actions on this Mac (plans/cmux-next/server.md 13). DEV and
/// NIGHTLY: the menu bar item and its panels render the bundled CLI's
/// `server status`; the launch agent registers only in builds that carry the
/// server software, and Stop Serving also reverts the helper's fixes and
/// removes the helper. Scripts use the Rust CLI's `cmux server …` verbs.
enum ServerHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let menuBar = context.services.serverMenuBar
        registry.bind("server.makeThisMacAServer", run: { _ in
            menuBar.show()
            do throws(ServerLaunchAgent.Failure) {
                try ServerLaunchAgent.register()
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
        registry.bind("server.addServer", run: { _ in menuBar.open(.approver) })
    }

    private static func refusal(for failure: ServerLaunchAgent.Failure) -> ActionFailure {
        switch failure {
        case .notInBuild:
            ActionFailure(message: RefusalStrings.text("refusal.server.notInBuild", "This build does not include the server software yet."))
        case .requiresApproval:
            ActionFailure(message: RefusalStrings.text("refusal.server.needsApproval", "Allow cmux in System Settings > Login Items, then try again."))
        case let .failed(reason):
            ActionFailure(message: RefusalStrings.format("refusal.server.registerFailed", "Could not start the server agent: %@", reason))
        }
    }
}
