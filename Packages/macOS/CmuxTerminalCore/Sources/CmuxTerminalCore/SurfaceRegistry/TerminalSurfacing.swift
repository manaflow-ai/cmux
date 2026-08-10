public import Foundation

/// Read-only cross-domain view of a registered terminal surface.
///
/// Implemented by the app's terminal surface model so the engine's surface
/// registry can track identity and focus placement without importing the
/// model layer. `id` is immutable for the surface's lifetime, while
/// `focusPlacement` is set at construction and read by the registry only while
/// registering on the creating thread. The registry owns the mutable terminal
/// process generation separately under its synchronization boundary. Renderer
/// ownership is immutable and is safe to read from any thread.
public protocol TerminalSurfacing: AnyObject {
    /// The stable identity of the terminal surface.
    var id: UUID { get }

    /// Where the surface participates in focus routing.
    var focusPlacement: TerminalSurfaceFocusPlacement { get }

    /// Whether another process owns the terminal state and GPU renderer.
    ///
    /// The registry uses this immutable classification to keep external
    /// terminals out of in-process renderer-reclamation scans.
    var isExternallyManaged: Bool { get }
}
