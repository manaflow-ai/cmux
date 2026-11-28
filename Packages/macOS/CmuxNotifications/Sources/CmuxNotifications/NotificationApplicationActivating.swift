/// Activates the host application in response to notification actions that
/// should bring the in-app Feed UI forward.
@MainActor
public protocol NotificationApplicationActivating: AnyObject {
    /// Activates the host application.
    func activateApplication()
}
