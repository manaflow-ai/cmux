import AppKit

extension AgentPaneView {
    /// Start Dictation (the Dictation key, Edit ▸ Start Dictation) from this pane's page, taken on
    /// its way up the responder chain to NSApplication (``AgentPaneDictationKey``): the pane's own
    /// dictation, or macOS's with the `agent.systemDictation` Debug toggle on.
    @objc(startDictation:) func startDictation(_ sender: Any?) {
        if dictationKey.usesSystemDictation { dictationKey.system(sender) } else { dictationKey.pane(self) }
    }
}
