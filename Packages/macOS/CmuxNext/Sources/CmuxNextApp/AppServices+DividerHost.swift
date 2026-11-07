import CmuxNextActions

extension AppServices: DividerActionHost {
    func dividerWorkspace(_ invocation: ActionInvocation) -> (any DividerWorkspace)? { AppActionContext(services: self).dividerContent(invocation) }
}
