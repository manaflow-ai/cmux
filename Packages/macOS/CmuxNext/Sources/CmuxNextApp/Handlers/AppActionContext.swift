import CmuxNextActions

/// What every `*Handlers.bind(into:context:)` binds against: the app's
/// services and target resolution for one invocation.
struct AppActionContext {
    let services: AppServices

    var registry: ActionRegistry { services.registry }

    /// The invocation's target, else the active window's focus.
    func scope(_ invocation: ActionInvocation = ActionInvocation()) -> ActionScope {
        ActionScope(services: services, invocation: invocation)
    }
}
