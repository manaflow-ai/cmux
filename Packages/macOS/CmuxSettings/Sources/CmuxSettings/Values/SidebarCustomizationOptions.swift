import Foundation

/// How eagerly the collapsed sidebar's hover-reveal responds to the pointer.
public enum SidebarPeekRevealPreset: String, CaseIterable, Sendable, SettingCodable {
    /// No dwell at all: touching the edge strip reveals immediately.
    case instant
    /// The shipped default: a short rest distinguishes intent from transit.
    case quick
    /// A longer rest and a narrower strip, for pointers that live near the
    /// window edge.
    case relaxed
}

/// Vertical breathing room inside each workspace row.
public enum SidebarRowDensity: String, CaseIterable, Sendable, SettingCodable {
    case compact
    case cozy
    case spacious
}

/// How the selected workspace row is highlighted.
public enum SidebarSelectionAccent: String, CaseIterable, Sendable, SettingCodable {
    /// The app accent colour as a solid pill.
    case blue
    /// A translucent grey pill that reads as a lighter patch of the glass.
    case glass
}
