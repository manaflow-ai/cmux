/// AppKit hosting strategy for a window backdrop.
public enum WindowBackdropHostingPhase: String, Equatable, Sendable {
    /// The window is opaque and filled directly.
    case opaqueWindowFill

    /// The window is transparent and uses a root backdrop layer.
    case transparentRootBackdrop

    /// The window uses native or fallback glass.
    case windowGlass
}
