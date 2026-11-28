#if canImport(AppKit)

public import AppKit

/// Selectable title-visibility modes for the About Titlebar Debug editor,
/// mapping directly onto `NSWindow.TitleVisibility`.
public enum TitlebarVisibilityOption: String, CaseIterable, Identifiable, Sendable {
    /// Hide the window title text.
    case hidden
    /// Show the window title text.
    case visible

    /// Stable identity for SwiftUI list iteration.
    public var id: String { rawValue }

    /// Human-readable label shown in the picker.
    public var displayTitle: String {
        switch self {
        case .hidden:
            return "Hidden"
        case .visible:
            return "Visible"
        }
    }

    /// The corresponding AppKit `NSWindow.TitleVisibility` value.
    public var windowValue: NSWindow.TitleVisibility {
        switch self {
        case .hidden:
            return .hidden
        case .visible:
            return .visible
        }
    }
}

#endif
