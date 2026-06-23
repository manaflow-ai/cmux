public import Foundation
public import SwiftUI
import AppKit

/// The tint the debug-only browser dev-tools toolbar button can use.
///
/// Each case's `rawValue` is the byte-identical `browserDevToolsIconColor`
/// `UserDefaults` string the debug picker writes and ``BrowserDevToolsButtonDebugRepository``
/// reads, so the persisted selection round-trips exactly as it did in the app target.
/// ``title`` is the human label shown in the debug picker.
///
/// The non-accent cases resolve to `NSColor`-derived label tints, which are available
/// in the package. The `.accent` case maps to the live app accent color, which is
/// app-target-only (`cmuxAccentColor()`), so the resolver takes that color as an
/// injected `accent` parameter rather than reaching into the app. The app passes
/// `cmuxAccentColor()` at the call site, inverting the dependency.
public enum BrowserDevToolsIconColorOption: String, CaseIterable, Identifiable, Sendable {
    case bonsplitInactive
    case bonsplitActive
    case accent
    case tertiary

    /// The stable identity used by `Identifiable`, equal to the persisted `rawValue`.
    public var id: String { rawValue }

    /// The human-readable label shown in the debug color picker.
    public var title: String {
        switch self {
        case .bonsplitInactive: return "Bonsplit Inactive (Terminal/Globe)"
        case .bonsplitActive: return "Bonsplit Active (Terminal/Globe)"
        case .accent: return "Accent"
        case .tertiary: return "Tertiary"
        }
    }

    /// The resolved SwiftUI tint for this option.
    ///
    /// The non-accent cases derive from `NSColor` label tints. The `.accent` case
    /// returns the caller-supplied `accent` color: the app passes `cmuxAccentColor()`
    /// (app-target-only), keeping this package off the app accent-color logic.
    public func color(accent: Color) -> Color {
        switch self {
        case .bonsplitInactive:
            // Matches Bonsplit tab icon tint for inactive tabs.
            return Color(nsColor: .secondaryLabelColor)
        case .bonsplitActive:
            // Matches Bonsplit tab icon tint for active tabs.
            return Color(nsColor: .labelColor)
        case .accent:
            return accent
        case .tertiary:
            return Color(nsColor: .tertiaryLabelColor)
        }
    }
}
