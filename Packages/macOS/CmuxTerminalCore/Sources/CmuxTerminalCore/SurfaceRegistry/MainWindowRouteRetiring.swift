/// Audits recoverable main-window routes after terminal topology changes.
///
/// Inverts the registry's legacy reach-up into the app delegate: when a
/// terminal surface unregisters, the owner can re-evaluate route lifecycle
/// without the terminal package depending on app-owned window state. The app
/// delegate conforms and is attached to the registry at composition time.
@MainActor
public protocol MainWindowRouteRetiring: AnyObject {
    /// Retires recoverable main-window routes whose owning lifecycle ended.
    ///
    /// - Parameter reason: A diagnostic label naming the trigger.
    func retireInactiveRecoverableMainWindowRoutes(reason: String)
}
