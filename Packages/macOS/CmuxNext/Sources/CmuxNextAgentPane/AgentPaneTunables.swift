public import CmuxNextDesign
import CmuxNextPages

/// Debug Settings declarations of the agent pane (DEV and NIGHTLY).
public nonisolated struct AgentPaneTunables {
    public nonisolated init() {}
    /// The agent pane move (react-pages.md): host new agent tabs on the shared page host
    /// (`cmux-page://cmux.agent/`) instead of the pane's own host. Off until the move is done; this
    /// tunable goes with the old host (P5).
    public static let pageHost = Tunable<Bool>.toggle(
        "agent.pageHost", PageTunables.section, "Agent pane on the page host",
        help: "New agent tabs load cmux-page://cmux.agent/ on the shared page host.",
        default: false, code: "AgentPaneTunables.pageHost")

    /// Side sessions: the composer's `/btw <question>` opens a read-only side session about the chat
    /// beside it, and the palette offers Ask a Side Question… (``ActionRegistry/publishSideSessions()``).
    /// Off by default; the page reads it from the header state (``AgentPaneHeaderState/sideSessions``).
    public static let sideSessions = Tunable<Bool>.toggle(
        "agentPane.debug.sideSessions", PageTunables.section, "Side sessions (/btw)",
        help: "The composer's /btw opens a read-only side session beside the chat, and the palette offers Ask a Side Question….",
        default: false, code: "AgentPaneTunables.sideSessions")

    /// Long thoughts fold once done (webviews conversation/ThoughtRow.tsx): a thought taller than
    /// the transcript's view folds to one line that opens to its text. Off keeps every thought in
    /// full (Leo 2026-10-13, #20330) until Leo picks the default. New agent tabs read it.
    public static let foldLongThoughts = Tunable<Bool>.toggle(
        "agentPane.debug.foldLongThoughts", PageTunables.section, "Fold long thoughts in the agent pane",
        help: "A finished thought taller than the transcript folds to one line that opens to its text. New agent tabs.",
        default: false, code: "AgentPaneTunables.foldLongThoughts")

    /// The page's `<html>` `data-*` attributes from these tunables.
    static var documentAttributes: [String: String] {
        foldLongThoughts.value ? ["fold-long-thoughts": "on"] : [:]
    }

    /// `documentAttributes` as a script run at document start, for the pane's own web view. Names
    /// and values are the fixed lowercase strings above, so they need no escaping.
    static var documentScript: String? {
        guard !documentAttributes.isEmpty else { return nil }
        let sets = documentAttributes.keys.sorted().map { name in
            "document.documentElement.setAttribute('data-\(name)', '\(documentAttributes[name] ?? "")');"
        }.joined(separator: " ")
        // At document start the parser may not have made <html> yet; the page's scripts run later.
        return "(() => { const set = () => { \(sets) }; if (document.documentElement) set(); else document.addEventListener('readystatechange', set, { once: true }); })();"
    }

    public static var all: [TunableDescriptor] { [pageHost.descriptor, foldLongThoughts.descriptor, sideSessions.descriptor] }
}
