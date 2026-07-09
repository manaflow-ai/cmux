#if canImport(AppKit)
#if DEBUG

/// One selectable icon row in the ``DebugWindowControlsView`` "Browser DevTools
/// Button" section.
///
/// The source `BrowserDevToolsIconOption` enum lives in the app target, where its
/// raw value doubles as the browser toolbar button's SF Symbol name. The debug
/// panel only needs each option's persisted raw value (which is also the symbol
/// name shown in the preview) and its human-readable title, so the app snapshots
/// `BrowserDevToolsIconOption.allCases` into these value rows and injects the
/// ordered list. The package view therefore holds no reference to the app-target
/// enum.
///
/// `rawValue` is the byte-identical `browserDevToolsIconName` `UserDefaults` string
/// the picker writes when a row is selected, matching the legacy app-side
/// `@AppStorage` contract exactly. It is also the SF Symbol name the preview
/// renders, mirroring the legacy `Image(systemName: selectedOption.rawValue)`.
public struct DebugBrowserDevToolsIconOption: Identifiable, Sendable {
    /// The `browserDevToolsIconName` raw string this row selects, also the SF
    /// Symbol name shown in the preview.
    public let rawValue: String

    /// The option's human-readable title shown in the picker.
    public let title: String

    /// Stable identity for `ForEach`, keyed on the persisted raw value (matching
    /// the legacy `ForEach(BrowserDevToolsIconOption.allCases)` with the enum's
    /// `id == rawValue`).
    public var id: String { rawValue }

    /// Creates a snapshot of one app-target browser-devtools icon option.
    ///
    /// - Parameters:
    ///   - rawValue: The persisted raw string, also the preview SF Symbol name.
    ///   - title: The option's human-readable title.
    public init(rawValue: String, title: String) {
        self.rawValue = rawValue
        self.title = title
    }
}

#endif
#endif
