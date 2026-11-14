public import CmuxNextSettings
public import Foundation

/// Files another app sends to a chat (Leo, 2026-11-08, on screenshots that can't reach a chat from
/// another app: "those NEED to be written down and FIXED and IMPROVED"): the App's one route for
/// them (`ExternalChatAttach`) hands them here, and they go into the composer as an unsent draft.
extension AgentPaneView {
    /// Puts the files at `urls` into this chat's composer as an unsent draft, as if the person had
    /// dropped them on it, and gives the composer the keyboard. `claimed`: the bundle id of the app
    /// they came from, when known (a file's own metadata, a screenshot's, still says first). The page
    /// takes them when it gets the command (`chat.attach.external`); a page still loading gets it
    /// once it subscribes.
    public func attachExternal(_ urls: [URL], claimed: String?) {
        guard !urls.isEmpty else { return }
        model.droppedPaths.hold(external: urls, claimed: claimed)
        focusChat()
        deliver([.command("attachExternal")], scripts: ["window.cmuxAcpmuxBridge?.command?.(\"attachExternal\");"])
    }

    /// What this chat's composer holds now, for `chat.composer.get`: `{session, attachments: [{name,
    /// mimeType, bytes, source}], text}` (``AgentPaneModel/composerJSON(session:page:kept:)``). The
    /// page answers for its own composer; a page that can't (an older one, or past `timeout`) leaves
    /// the chips the chat keeps for its draft.
    public func composerReadback(timeout: Duration = .milliseconds(1500)) async -> JSONValue {
        let session = model.sessionId
        let answer = try? await callPageScript("return window.cmuxAcpmuxBridge?.composerState?.() ?? null", timeout: timeout)
        let page = answer.flatMap { JSONValue(foundation: $0) }
        var kept: [AgentPaneWakeState.Attachment] = []
        if page == nil || page == .null, let session, let store = AgentPaneDraftAttachments.shared {
            kept = await store.attachments(for: session)
        }
        return AgentPaneModel.composerJSON(session: session, page: page, kept: kept)
    }
}
