#if os(iOS)
extension TerminalComposerView {
    /// Whether the field's text alone is empty. Drives only secondary visuals;
    /// the Send affordance keys on ``canSend`` so an images-only message (empty
    /// text, attachments staged) is still sendable in terminal mode.
    var trimmedIsEmpty: Bool {
        store.terminalInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Send follows terminal attachment rules normally, but agent routing accepts text only.
    var canSend: Bool {
        if submitRouter?.isAgentGUIRouting == true {
            return !trimmedIsEmpty
        }
        return store.composerCanSend(forTerminalID: terminalID)
    }
}

extension Optional where Wrapped == TerminalComposerSubmitRouter {
    @MainActor
    func submit(fallback: @MainActor () async -> Void) async {
        if let self {
            await self.submit(fallback: fallback)
        } else {
            await fallback()
        }
    }
}
#endif
