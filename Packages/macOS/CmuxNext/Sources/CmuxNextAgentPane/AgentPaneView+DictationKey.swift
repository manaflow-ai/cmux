public import AppKit

extension AgentPaneView {
    /// Start Dictation (the Dictation key, Edit ▸ Start Dictation) from this pane's page, taken on
    /// its way up the responder chain to NSApplication (``AgentPaneDictationKey``): the pane's own
    /// dictation, or macOS's with the `agent.systemDictation` Debug toggle on.
    @objc(startDictation:) func startDictation(_ sender: Any?) {
        if dictationKey.usesSystemDictation { dictationKey.system(sender) } else { dictationKey.pane(self) }
    }

    /// Start Dictation as NSApplication gets it (Edit ▸ Start Dictation, its Globe-D key
    /// equivalent): toggles the dictation of the agent pane whose page has the keyboard in
    /// `keyWindow`. False, for macOS's own dictation, when no agent pane has it or the
    /// `agent.systemDictation` Debug toggle is on.
    @discardableResult
    public static func takeStartDictation(in keyWindow: NSWindow?, sender: Any?) -> Bool {
        false
    }
}
