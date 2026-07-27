/// Retires recoverable main-window routes after surface unregistration.
///
/// Inverts the registry's legacy reach-up into the app delegate: when a
/// terminal surface unregisters, window routes that were kept recoverable for
/// it may no longer have any registered surface and must be retired. The app
/// delegate conforms and is attached to the registry at composition time.
@MainActor
public protocol MainWindowRouteRetiring: AnyObject {
    /// Retires every recoverable main-window route that no longer has a
    /// registered terminal surface.
    ///
    /// - Parameter reason: A diagnostic label naming the trigger.
    func retireRecoverableMainWindowRoutesWithoutRegisteredTerminalSurfaces(reason: String)
}
