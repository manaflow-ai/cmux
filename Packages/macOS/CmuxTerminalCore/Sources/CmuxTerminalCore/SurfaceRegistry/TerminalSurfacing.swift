public import Foundation

/// Read-only cross-domain view of a registered terminal surface.
///
/// Implemented by the app's terminal surface model so the engine's surface
/// registry can track identity and focus placement without importing the
/// model layer. Identity requirements must be safe to read from any thread:
/// `id` and `terminalLifecycleID` are immutable for the surface's lifetime,
/// and `focusPlacement` is set at construction and read by the registry only
/// while registering on the creating thread.
public protocol TerminalSurfacing: AnyObject {
    /// The stable identity of the terminal surface.
    var id: UUID { get }

    /// The unique identity of this terminal process generation.
    var terminalLifecycleID: UUID { get }

    /// Where the surface participates in focus routing.
    var focusPlacement: TerminalSurfaceFocusPlacement { get }
}
