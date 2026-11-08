public import Foundation

/// Schedules targeted renderer-presentation repairs for the surface model.
///
/// Implemented by the app's `RendererRealizationController`; the surface
/// callback passes only its stable id after Ghostty drains the renderer mailbox.
public protocol TerminalRendererRealizationScheduling: AnyObject, Sendable {
    /// Requests a presentation repair for one surface after renderer activity.
    ///
    /// - Parameter surfaceID: The stable id of the surface whose enqueue failed.
    @MainActor
    func scheduleRendererPresentationRepair(surfaceID: UUID)
}
