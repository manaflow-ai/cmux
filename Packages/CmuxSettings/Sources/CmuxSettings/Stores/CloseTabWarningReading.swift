import Foundation

/// Read access to the close-tab warning settings.
///
/// Consumer domains (workspace close flows, tab chrome) depend on this seam
/// instead of the concrete ``CloseTabWarningStore`` so they can be tested
/// with a fixed fake and never name the storage mechanism.
public protocol CloseTabWarningReading: Sendable {
    /// Whether closing a tab via the close shortcut warns first when the tab
    /// requires confirmation.
    var warnsBeforeClosingTab: Bool { get }

    /// Whether closing a tab via its X button always warns first.
    var warnsBeforeClosingTabXButton: Bool { get }

    /// Whether the tab close (X) button is hidden entirely.
    var hidesTabCloseButton: Bool { get }
}
