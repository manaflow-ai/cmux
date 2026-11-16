import CmuxNextActions
import CmuxNextDaemonService

extension AppServices: DividerActionHost {
    func dividerWorkspace(_ invocation: ActionInvocation) -> (any DividerWorkspace)? { let ctx = AppActionContext(services: self); return ctx.scope(invocation).workspace.flatMap(ctx.content(showing:)) }
}
