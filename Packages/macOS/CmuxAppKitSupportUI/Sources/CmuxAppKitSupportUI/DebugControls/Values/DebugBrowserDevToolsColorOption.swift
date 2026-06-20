#if canImport(AppKit)
#if DEBUG

public import SwiftUI

/// One selectable color row in the ``DebugWindowControlsView`` "Browser DevTools
/// Button" section.
///
/// The source `BrowserDevToolsIconColorOption` enum lives in the app target, where
/// its `color` resolves app-coupled values (one case maps to the live app accent
/// color via `cmuxAccentColor()`). The debug panel only needs each option's
/// persisted raw value, its human-readable title, and the already-resolved preview
/// `Color`, so the app snapshots `BrowserDevToolsIconColorOption.allCases` into
/// these value rows and injects the ordered list. The package view therefore holds
/// no reference to the app-target enum or to the app accent-color logic.
///
/// `rawValue` is the byte-identical `browserDevToolsIconColor` `UserDefaults` string
/// the picker writes when a row is selected, matching the legacy app-side
/// `@AppStorage` contract exactly.
public struct DebugBrowserDevToolsColorOption: Identifiable {
    /// The `browserDevToolsIconColor` raw string this row selects.
    public let rawValue: String

    /// The option's human-readable title shown in the picker.
    public let title: String

    /// The resolved preview color, computed app-side so the package never names
    /// the app accent-color logic. Matches the legacy `option.color`.
    public let color: Color

    /// Stable identity for `ForEach`, keyed on the persisted raw value (matching
    /// the legacy `ForEach(BrowserDevToolsIconColorOption.allCases)` with the
    /// enum's `id == rawValue`).
    public var id: String { rawValue }

    /// Creates a snapshot of one app-target browser-devtools color option.
    ///
    /// - Parameters:
    ///   - rawValue: The persisted raw string this row selects.
    ///   - title: The option's human-readable title.
    ///   - color: The already-resolved preview color.
    public init(rawValue: String, title: String, color: Color) {
        self.rawValue = rawValue
        self.title = title
        self.color = color
    }
}

#endif
#endif
