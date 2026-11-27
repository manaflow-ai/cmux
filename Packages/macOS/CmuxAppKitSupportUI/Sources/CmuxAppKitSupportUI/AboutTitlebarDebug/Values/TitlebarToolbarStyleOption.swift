#if canImport(AppKit)

public import AppKit

/// Selectable toolbar-style modes for the About Titlebar Debug editor,
/// mapping directly onto `NSWindow.ToolbarStyle`.
public enum TitlebarToolbarStyleOption: String, CaseIterable, Identifiable, Sendable {
    /// System-chosen toolbar style.
    case automatic
    /// Expanded toolbar style.
    case expanded
    /// Preference-window toolbar style.
    case preference
    /// Unified toolbar style.
    case unified
    /// Unified compact toolbar style.
    case unifiedCompact

    /// Stable identity for SwiftUI list iteration.
    public var id: String { rawValue }

    /// Human-readable label shown in the picker.
    public var displayTitle: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .expanded:
            return "Expanded"
        case .preference:
            return "Preference"
        case .unified:
            return "Unified"
        case .unifiedCompact:
            return "Unified Compact"
        }
    }

    /// The corresponding AppKit `NSWindow.ToolbarStyle` value.
    public var windowValue: NSWindow.ToolbarStyle {
        switch self {
        case .automatic:
            return .automatic
        case .expanded:
            return .expanded
        case .preference:
            return .preference
        case .unified:
            return .unified
        case .unifiedCompact:
            return .unifiedCompact
        }
    }
}

#endif
