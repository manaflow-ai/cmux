public import AppKit

extension AgentPaneView {
    /// Start Dictation sent up the responder chain from this pane's page (``AgentPaneDictationKey``):
    /// the pane's own dictation, or macOS's with the `agent.systemDictation` Debug toggle on. The
    /// Dictation key and Edit ▸ Start Dictation go to NSApplication instead, which asks
    /// ``takeStartDictation(in:sender:)``.
    @objc(startDictation:) func startDictation(_ sender: Any?) {
        if dictationKey.usesSystemDictation { dictationKey.system(sender) } else { dictationKey.pane(self) }
    }

    /// Start Dictation as NSApplication gets it (Edit ▸ Start Dictation, its Globe-D key
    /// equivalent): toggles the dictation of the agent pane whose page has the keyboard in
    /// `keyWindow`. False, for macOS's own dictation, when no agent pane has it or the
    /// `agent.systemDictation` Debug toggle is on.
    @discardableResult
    public static func takeStartDictation(in keyWindow: NSWindow?, sender: Any?) -> Bool {
        guard let keyWindow, let pane = dictationOwner(in: keyWindow), !pane.dictationKey.usesSystemDictation else { return false }
        pane.dictationKey.pane(pane)
        return true
    }

    /// The agent pane whose page has the keyboard in `keyWindow`: the pane holding its first
    /// responder (WebKit), or the pane whose Chromium page window it is (a child of the pane's window).
    static func dictationOwner(in keyWindow: NSWindow) -> AgentPaneView? {
        var view = keyWindow.firstResponder as? NSView
        while let current = view {
            if let pane = current as? AgentPaneView { return pane }
            view = current.superview
        }
        guard let root = keyWindow.parent?.contentView else { return nil }
        return panes(in: root).first { $0.dictationKey.pageWindow($0) === keyWindow }
    }

    private static func panes(in view: NSView) -> [AgentPaneView] {
        if let pane = view as? AgentPaneView { return [pane] }
        return view.subviews.flatMap { panes(in: $0) }
    }
}
