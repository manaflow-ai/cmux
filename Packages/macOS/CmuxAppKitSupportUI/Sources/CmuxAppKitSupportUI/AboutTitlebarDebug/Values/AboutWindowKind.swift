#if canImport(AppKit)

public import AppKit

/// Identifies an About-family window whose titlebar can be tuned by the
/// About Titlebar Debug subsystem.
///
/// Today there is a single case, ``about``, but the kind is modeled as an enum so
/// the debug store, window controller, and editor view can scale to additional
/// About-style windows without changing their shapes.
public enum AboutWindowKind: String, CaseIterable, Identifiable, Sendable {
    /// The primary "About cmux" window.
    case about

    /// Stable identity for SwiftUI list iteration.
    public var id: String { rawValue }

    /// Human-readable label shown as the editor section title.
    public var displayTitle: String {
        switch self {
        case .about:
            return "About Window"
        }
    }

    /// `NSWindow.identifier` value used to find the live window when reapplying
    /// debug options to already-open windows.
    public var windowIdentifier: String {
        switch self {
        case .about:
            return "cmux.about"
        }
    }

    /// Title used when the debug-overridden title resolves to empty.
    public var fallbackTitle: String {
        switch self {
        case .about:
            return "About cmux"
        }
    }

    /// Minimum content size enforced on the window for this kind.
    public var minimumSize: NSSize {
        switch self {
        case .about:
            return NSSize(width: 360, height: 520)
        }
    }
}

#endif
