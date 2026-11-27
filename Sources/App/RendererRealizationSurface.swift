import Foundation

/// The narrow renderer lifecycle surface consumed by the reclamation policy.
/// Keeping this seam independent of the concrete terminal model lets scheduler
/// tests exercise real notifications, cancellation, and deadlines without
/// constructing a Ghostty runtime.
@MainActor
protocol RendererRealizationSurface: AnyObject {
    var id: UUID { get }
    var hasLiveSurface: Bool { get }
    var isRendererPortalVisible: Bool { get }
    var isRendererEffectivelyVisible: Bool { get }
    var isRendererRealized: Bool { get }
    var isRendererPresented: Bool { get }
    var rendererLastVisibleAt: TimeInterval { get }

    func noteBecameVisibleForRendererReclamation()
    func ensureRendererPresented()
    func releaseRenderer() -> Bool
    func retryRendererPresentationAfterActivity()
}
