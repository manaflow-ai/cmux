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

    /// Long thoughts fold once done (webviews conversation/ThoughtRow.tsx): a thought taller than
    /// the transcript's view folds to one line that opens to its text. Off keeps every thought in
    /// full (Leo 2026-10-13, #20330) until Leo picks the default. New agent tabs read it.
    public static let foldLongThoughts = Tunable<Bool>.toggle(
        "agentPane.debug.foldLongThoughts", PageTunables.section, "Fold long thoughts in the agent pane",
        help: "A finished thought taller than the transcript folds to one line that opens to its text. New agent tabs.",
        default: false, code: "AgentPaneTunables.foldLongThoughts")

    /// Tool runs fold as the Codex desktop app folds them while a turn runs (webviews
    /// conversation/turns.ts `codexRuns`, cx-ncc.108): the run in flight is one line naming its
    /// newest call, and a run that text followed settles into its summary line. Off keeps every
    /// call's row until Leo picks the default. New agent tabs read it.
    public static let codexToolRuns = Tunable<Bool>.toggle(
        "agentPane.debug.codexToolRuns", PageTunables.section, "Codex-style tool runs in the agent pane",
        help: "While a turn runs, each run of tool calls is one line: the newest call, then a summary once text follows. New agent tabs.",
        default: false, code: "AgentPaneTunables.codexToolRuns")

    /// The page's `<html>` `data-*` attributes from these tunables.
    static var documentAttributes: [String: String] {
        var attributes: [String: String] = [:]
        if foldLongThoughts.value { attributes["fold-long-thoughts"] = "on" }
        if codexToolRuns.value { attributes["codex-tool-runs"] = "on" }
        return attributes
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

    public static var all: [TunableDescriptor] { [pageHost.descriptor, foldLongThoughts.descriptor, codexToolRuns.descriptor] }
}
