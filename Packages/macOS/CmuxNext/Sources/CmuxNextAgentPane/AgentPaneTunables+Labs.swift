public import CmuxNextDesign
import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// Files and linked files open in one viewer beside the transcript, inside the chat, instead of a
    /// new column or a tab over the chat; Changes opens as without the switch (Lucas 2026-10-19).
    public static let chatViewer = Tunable<Bool>.toggle(
        "agentPane.labs.chatViewer", PageTunables.section, "Files beside the chat",
        help: "Files and files the chat links to open in one viewer beside the transcript, inside the chat, instead of a new column or a tab over the chat. Changes opens as before. New agent tabs.",
        default: true, code: "AgentPaneTunables.chatViewer")
    static let labTunables: [String: Tunable<Bool>] = ["chat-viewer": chatViewer]
}
