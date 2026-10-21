import AppKit
import CmuxNextDesign

/// Where macOS's Start Dictation goes from an agent pane.
///
/// The Dictation key (fn, the 🎤 key) and Edit ▸ Start Dictation send `startDictation:` up the
/// responder chain to NSApplication, which shows macOS's black dictation overlay at the text-input
/// caret WebKit reports, over the composer's corner. ``AgentPaneView`` takes the action on its way
/// up: with the `agent.systemDictation` Debug toggle off (the default) it toggles the pane's own
/// dictation, as the composer's mic does, so a second press finishes it; on, it hands the action to
/// NSApplication. Only a first responder inside an agent pane reaches the pane, so terminals,
/// browsers and other panes keep macOS's dictation.
struct AgentPaneDictationKey {
    /// The action the Dictation key and the Edit menu item send (NSApplication implements it).
    static let action = Selector(("startDictation:"))

    /// Debug Settings (tests pass their own).
    var tunables: TunableStore = .shared
    /// Toggles the pane's dictation: a press starts it, the next one finishes it.
    var pane: @MainActor (AgentPaneView) -> Void = { $0.toggleDictation(from: nil) }
    /// macOS's dictation: NSApplication's own `startDictation:`.
    var system: @MainActor (Any?) -> Void = { sender in _ = NSApp.tryToPerform(AgentPaneDictationKey.action, with: sender) }

    /// Whether the action goes to macOS's dictation instead of the pane's.
    var usesSystemDictation: Bool { AgentPaneTunables.systemDictation.value(in: tunables) }
}
