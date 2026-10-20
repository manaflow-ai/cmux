import AppKit
import CmuxNextActions
import CmuxNextDesign

/// What every `*Handlers.bind(into:context:)` binds against: the app's
/// services and target resolution for one invocation.
struct AppActionContext {
    let services: AppServices
    /// Where handlers apply a setting's live value before writing it.
    /// Tests pass their own so parallel suites keep the shared one.
    var design: DesignSettings = .shared
    /// What Copy actions run (``copy(_:)``): writes the general pasteboard.
    /// Tests pass their own, so a run never needs the pasteboard server.
    var writeToPasteboard: @MainActor @Sendable (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var registry: ActionRegistry { services.registry }

    /// The invocation's target, else the active window's focus.
    func scope(_ invocation: ActionInvocation = ActionInvocation()) -> ActionScope {
        ActionScope(services: services, invocation: invocation)
    }
}
