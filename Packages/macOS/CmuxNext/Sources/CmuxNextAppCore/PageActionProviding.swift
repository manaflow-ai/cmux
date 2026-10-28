public import CmuxNextActions

/// The small action surface needed by page features. Registration and the
/// concrete ActionRegistry remain owned by CmuxNextApp.
@MainActor
public protocol PageActionProviding: AnyObject {
    func actionDescriptor(for id: ActionID) -> ActionDescriptor?
    func actionTitle(for id: ActionID) -> String?
    func isActionAvailable(_ id: ActionID) -> Bool
    @discardableResult
    func performAction(_ id: ActionID, invocation: ActionInvocation) -> Bool
}
