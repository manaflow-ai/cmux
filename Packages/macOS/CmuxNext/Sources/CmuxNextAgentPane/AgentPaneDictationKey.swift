import AppKit
import CmuxNextDesign

/// Where macOS's Start Dictation goes from an agent pane.
///
/// AppKit adds Edit ▸ Start Dictation to the app's Edit menu with NSApplication as its target and
/// Globe-D (fn-D) as its key equivalent, so the key and the menu item call NSApplication's
/// `startDictation:` directly: no responder sees the action, and macOS's black dictation overlay
/// shows at the text-input caret, over the composer's corner. The app's NSApplication asks
/// ``AgentPaneView/takeStartDictation(in:sender:)`` first. When the keyboard is in an agent pane's
/// page, in the pane's window (WebKit) or in the Chromium page window over the pane, and the
/// `agent.systemDictation` Debug toggle is off (the default), the pane's own dictation toggles, as
/// the composer's mic does, so a second press finishes it. Terminals, browsers and other panes keep
/// macOS's dictation. ``AgentPaneView`` also takes a `startDictation:` sent up the responder chain.
struct AgentPaneDictationKey {
    /// The action the Dictation key and the Edit menu item send (NSApplication implements it).
    static let action = Selector(("startDictation:"))

    /// Debug Settings (tests pass their own).
    var tunables: TunableStore = .shared
    /// Toggles the pane's dictation: a press starts it, the next one finishes it.
    var pane: @MainActor (AgentPaneView) -> Void = { $0.toggleDictation(from: nil) }
    /// macOS's dictation: NSApplication's own `startDictation:`.
    var system: @MainActor (Any?) -> Void = { sender in _ = NSApp.tryToPerform(AgentPaneDictationKey.action, with: sender) }

    /// The Chromium page window that shows the pane's chat over it, nil on WebKit (tests pass their own).
    var pageWindow: @MainActor (AgentPaneView) -> NSWindow? = { $0.chromiumPage?.contentView.window }

    /// Whether the action goes to macOS's dictation instead of the pane's.
    var usesSystemDictation: Bool { AgentPaneTunables.systemDictation.value(in: tunables) }
}
