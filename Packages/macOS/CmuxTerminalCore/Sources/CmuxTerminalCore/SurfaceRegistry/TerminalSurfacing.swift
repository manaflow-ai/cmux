public import Foundation

/// Read-only cross-domain view of a registered terminal surface.
///
/// Implemented by the app's terminal surface model so the engine's surface
/// registry can track identity and focus placement without importing the
/// model layer. `id` is immutable for the surface's lifetime, while
/// `focusPlacement` is set at construction and read by the registry only while
/// registering on the creating thread. The registry owns the mutable terminal
/// process generation separately under its synchronization boundary.
public protocol TerminalSurfacing: AnyObject {
    /// The stable identity of the terminal surface.
    var id: UUID { get }

    /// Where the surface participates in focus routing.
    var focusPlacement: TerminalSurfaceFocusPlacement { get }
}
