public import CmuxNextActions

// Toggle Dictation's palette switch (the user, 2026-11-03: "'toggle' options are very confusing,
// since we don't know the current state"): on while the dictation a run would end is listening.

extension AgentPaneDictation {
    /// A session is starting, listening or finishing: a toggle now ends it.
    var isListening: Bool { !phase.isStartable }
}

extension DictationMicrophone {
    /// Some agent pane's dictation listens.
    var isListening: Bool { listening?.isListening == true }
}

extension AgentPaneView {
    /// This chat's composer dictation listens: Toggle Dictation on it now stops it.
    public var isDictating: Bool { dictation.isListening }
}

extension ActionRegistry {
    /// Sets Toggle Dictation's palette state to what a run would end now, following the app's
    /// handler: on a focused terminal, that terminal's dictation; elsewhere a terminal's dictation
    /// that still runs, else the focused chat's, else any chat's (with no chat focused a run stops
    /// the one that listens).
    /// - Parameter focusedTerminal: The focused tab is a terminal.
    /// - Parameter terminalListening: The terminal dictation listens.
    /// - Parameter focusedChat: The focused agent chat, nil when the focused tab is none.
    public func setDictationPaletteState(focusedTerminal: @escaping @MainActor () -> Bool,
                                         terminalListening: @escaping @MainActor () -> Bool,
                                         focusedChat: @escaping @MainActor () -> AgentPaneView?) {
        setDictationPaletteState(focusedTerminal: focusedTerminal, terminalListening: terminalListening,
                                 chatListening: { focusedChat()?.isDictating }, microphone: .shared)
    }

    /// ``setDictationPaletteState(focusedTerminal:terminalListening:focusedChat:)`` with the chat's
    /// dictation (nil: no chat focused) and the panes' microphone given (tests).
    func setDictationPaletteState(focusedTerminal: @escaping @MainActor () -> Bool,
                                  terminalListening: @escaping @MainActor () -> Bool,
                                  chatListening: @escaping @MainActor () -> Bool?,
                                  microphone: DictationMicrophone) {
        ActionTargetTitles.setPaletteState("palette.toggleDictation", in: self) {
            if focusedTerminal() { return terminalListening() }
            if terminalListening() { return true }
            return chatListening() ?? microphone.isListening
        }
    }
}
