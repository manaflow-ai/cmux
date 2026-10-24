import AppKit

/// A panel ``MadeAheadPanelStore`` can hand out again: `NSOpenPanel` (in `NSOpenPanel+ReusableOpenPanel.swift`),
/// or a test's stand-in, which a test host can make without the panel's view service.
@MainActor
protocol ReusableOpenPanel: OpenPanelLabels {
    /// Whether no sheet or window shows the panel now, so a click may take it.
    var isFreeForReuse: Bool { get }
    /// Puts back the choices a new panel starts with: one file, no folders, every type, aliases resolved.
    func resetChoices()
}
