/// Structural view of a surface-resume binding, exposing only the two
/// classification reads the resume-binding resolution algorithm consults, so
/// the package never imports the app's concrete `SurfaceResumeBindingSnapshot`
/// (a frozen Codable wire type owned by the app target).
///
/// The conformer is the app's persisted binding snapshot. The
/// ``SessionRestoreCoordinator`` reads `isProcessDetected` and asks the
/// conformer whether a stored binding should yield to a freshly detected one;
/// it never constructs a binding, keeping the wire format owned by the app
/// target.
public protocol SurfaceResumeBindingResolving {
    /// Whether this binding came from a process detector (legacy
    /// `SurfaceResumeBindingSnapshot.isProcessDetected`).
    var isProcessDetected: Bool { get }

    /// Whether a stored binding (`self`) should be replaced by a freshly
    /// detected one, reproducing the legacy
    /// `SurfaceResumeBindingSnapshot.shouldYieldToDetectedSurfaceResumeBinding(_:)`.
    func shouldYieldToDetectedSurfaceResumeBinding(_ detected: Self) -> Bool
}

/// The outcome of reconciling one panel's stored binding against the freshly
/// detected one during a session-restore reconcile pass, reproducing the three
/// branches of the legacy `Workspace.reconcileSurfaceResumeBindings(using:)`
/// loop body without the package owning the live `[UUID: Binding]` map.
///
/// The app applies the action to its own stored map; the coordinator only
/// decides.
public enum SurfaceResumeBindingReconcileAction<Binding>: Sendable where Binding: Sendable {
    /// Leave the stored binding (if any) unchanged for this panel.
    case keep
    /// Store the given binding for this panel (insert or overwrite).
    case store(Binding)
    /// Remove any stored binding for this panel.
    case remove
}

extension SurfaceResumeBindingReconcileAction: Equatable where Binding: Equatable {}
