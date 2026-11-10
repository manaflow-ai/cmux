import AppKit

/// The one text that tells a working open panel from a dead one: `NSSavePanel`'s prompt, read as an optional
/// (AppKit types it `String!`; it is nil when the panel's view service never answered: no GUI session,
/// 2026-10-23). Read through this protocol, never unwrapped, so ``MadeAheadPanelStore`` can be tested with
/// stand-in panels and no view service. `NSSavePanel` conforms in `NSSavePanel+OpenPanelLabels.swift`.
@MainActor
protocol OpenPanelLabels: AnyObject {
    /// The default button's text, nil when the panel never loaded its view.
    var openPanelPrompt: String? { get }
}
