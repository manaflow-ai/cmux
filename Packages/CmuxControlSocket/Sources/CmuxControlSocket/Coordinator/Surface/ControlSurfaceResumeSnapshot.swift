public import Foundation

/// A read-only snapshot of a successful resume operation for the
/// `surface.resume.*` payload.
///
/// Mirrors the legacy `v2SurfaceResumeResult` payload: the window/workspace/pane/
/// surface identity, the `cleared` flag, and the resulting binding. The coordinator
/// mints all refs and shapes the `resume_binding` value (a `nil` binding emits JSON
/// `null` for that key, matching the legacy `v2SurfaceResumeBindingPayload(nil)`).
public struct ControlSurfaceResumeSnapshot: Sendable, Equatable {
    /// The enclosing window's identifier, if it resolved.
    public let windowID: UUID?
    /// The workspace's identifier.
    public let workspaceID: UUID
    /// The surface's enclosing pane, if it resolved.
    public let paneID: UUID?
    /// The surface's identifier.
    public let surfaceID: UUID
    /// Whether the binding was cleared.
    public let cleared: Bool
    /// The resulting resume binding, or `nil`.
    public let binding: ControlSurfaceResumeBinding?

    /// Creates a resume snapshot.
    ///
    /// - Parameters:
    ///   - windowID: The enclosing window's identifier, if resolved.
    ///   - workspaceID: The workspace's identifier.
    ///   - paneID: The surface's enclosing pane, if resolved.
    ///   - surfaceID: The surface's identifier.
    ///   - cleared: Whether the binding was cleared.
    ///   - binding: The resulting resume binding.
    public init(
        windowID: UUID?,
        workspaceID: UUID,
        paneID: UUID?,
        surfaceID: UUID,
        cleared: Bool,
        binding: ControlSurfaceResumeBinding?
    ) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.surfaceID = surfaceID
        self.cleared = cleared
        self.binding = binding
    }
}
