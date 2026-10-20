import Foundation

/// The dispatcher commands the app sends the page: Continue in, Create checkpoint, the chat's
/// keyboard actions and the grouped-permission actions.
extension AgentPaneView {
    /// Opens the frontend's Continue in… chooser. The chooser owns target selection and
    /// preparation; native actions do not create a second handoff pipeline.
    public func showContinueIn() { send("continueIn") }
    /// Archive Chat (Ctrl-Cmd-A, cx-ncc.72): the page archives the chat the way its menu's Archive does.
    public func archiveChat() { send("archiveChat") }
    /// Opt-Cmd-B with `agentChat.sideColumn`: the page runs its New tab / Hide tabs, the chat's side column.
    public func toggleSideColumn() { send("sideTabs") }
    private func send(_ command: String) {
        deliver([.command(command)], scripts: ["window.cmuxAcpmuxBridge?.command?.(\"\(command)\");"])
    }
    /// Switch Model… (Ctrl-Cmd-M) and Search Files… (Cmd-P, cx-ncc.69): the page takes the keyboard,
    /// then opens its model picker, or the composer's file search (a pick mentions the file).
    public func showModelPicker() { showWithKeyboard("openModelPicker") }
    public func showFileSearch() { showWithKeyboard("searchFiles") }
    private func showWithKeyboard(_ command: String) {
        if webView.window?.firstResponder !== webView { webView.window?.makeFirstResponder(webView) }
        send(command)
    }
    /// Palette and page buttons enter the same inline checkpoint review.
    public func showCreateCheckpoint() { if model.checkpointAvailable { send("createCheckpoint") } }
    /// Previous and Next Turn (Ctrl-Opt-Up, Ctrl-Opt-Down) and Previous and Next Bookmarked Prompt
    /// (palette only): the page steps its transcript to that prompt, as the thread minimap does.
    public func step(_ step: AgentTranscriptStep) { send(step.pageCommand) }
    /// Runs a grouped-permission action from the app shortcut registry. The
    /// page keeps the decision scoped to its selected session and refuses
    /// stale, collecting, or unavailable groups before sending anything.
    public func runPermissionAction(_ command: String, byPerson: Bool) {
        let allowed = ["permissionAllowOnce", "permissionAllowChat", "permissionDeny", "permissionExpand",
                       "permissionRetry", "permissionRevoke", "permissionRefresh"]
        guard allowed.contains(command) else { return }
        // The person's shortcut is the gesture its answer uses; a posted key or script grants nothing.
        AgentPanePersonInput.record(model.transport.gestures, if: byPerson, answer: true)
        send(command)
    }
}
