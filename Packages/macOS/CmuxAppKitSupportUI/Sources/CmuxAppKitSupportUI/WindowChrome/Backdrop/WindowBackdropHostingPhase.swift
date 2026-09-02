/// AppKit hosting strategy for a window backdrop.
public enum WindowBackdropHostingPhase: String, Equatable, Sendable {
    /// The window stays opaque while a real root layer owns its backdrop.
    case opaqueRootBackdrop

    /// The window is transparent and uses a root backdrop layer.
    case transparentRootBackdrop

    /// The window uses native or fallback glass.
    case windowGlass
}
