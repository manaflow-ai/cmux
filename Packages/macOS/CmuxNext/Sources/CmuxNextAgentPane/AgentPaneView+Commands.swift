import CmuxNextSettings
import Foundation

/// The dispatcher commands the app sends the page: Continue in, Create checkpoint, the chat's
/// keyboard actions and the grouped-permission actions.
extension AgentPaneView {
    /// Toggles Session Info through the same page callback as the header button.
    public func toggleSessionInfo() { send("toggleSessionInfo") }
    /// Runs a header toggle the page offers now (``AgentPageCommand``, ``AgentPaneModel/pageCommands``).
    public func run(_ command: AgentPageCommand) {
        // A queued command belongs to this chat, even if the page selects another before delivery.
        let value = "header:\(command.rawValue)|\(model.sessionId ?? "")"
        deliver([.command(value)], scripts: ["window.cmuxAcpmuxBridge?.command?.(\(JSONValue.string(value).compactText));"])
    }

    /// Opens the frontend's Continue In… chooser. The chooser owns target selection and
    /// preparation; native actions do not create a second handoff pipeline.
    public func showContinueIn() { send("continueIn") }
    /// Archive Chat (Ctrl-Cmd-A, cx-ncc.72): the page archives the chat the way its menu's Archive does.
    public func archiveChat() { send("archiveChat") }
    /// Stop Agent Turn: the palette, keyboard and composer button use the same guarded stop path.
    public func stopTurn() {
        guard let session = model.sessionId else { return }
        let json = JSONValue.string(session).compactText
        deliver([AgentPageEvent(kind: "stopTurn", value: .string(session))],
                scripts: ["window.cmuxAcpmuxBridge?.command?.(\"stopTurn\",\(json));"])
    }
    private func send(_ command: String) {
        deliver([.command(command)], scripts: ["window.cmuxAcpmuxBridge?.command?.(\"\(command)\");"])
    }
    /// Switch Model… (Ctrl-Cmd-M) and Search Files… (Cmd-P, cx-ncc.69): the page takes the keyboard,
    /// then opens its model picker, or the composer's file search (a pick mentions the file).
    public func showModelPicker() { showWithKeyboard("openModelPicker") }
    public func showFileSearch() { showWithKeyboard("searchFiles") }
    /// Ask a Side Question… focuses this chat's composer and prefills `/btw `.
    /// The session id travels with the event so a palette run cannot land in a replacement chat.
    public func askSideQuestion() {
        guard let sessionId = model.sessionId else { return }
        focusChat()
        let json = JSONValue.string(sessionId).compactText
        deliver([.sideQuestion(sessionId)], scripts: ["window.cmuxAcpmuxBridge?.command?.(\"sideQuestion\",\(json));"])
    }
    /// A chat that just opened from a fork (``AgentForkDestination``): the keyboard goes to its
    /// composer, so the next words go to the fork.
    public func focusComposer() { showWithKeyboard("focusComposer") }
    private func showWithKeyboard(_ command: String) {
        focusChat()
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
