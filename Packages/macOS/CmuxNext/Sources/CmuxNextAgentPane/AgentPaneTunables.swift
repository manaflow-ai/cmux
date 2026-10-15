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

    /// How wide the chat's column draws on a wide pane (cx-ncc.107, a trial before real Settings).
    /// The page gets it with the theme (`AgentPaneTheme`, `chatWidth`), again on each change.
    public static let chatWidth = Tunable<ChatWidth>.choice(
        "agent.chatWidth", PageTunables.section, "Agent chat width",
        help: "Standard: 800px. Wide: 960px. Wide blocks: code, tables and tools 1120px, prose 800px.",
        default: .standard, code: "AgentPaneTunables.chatWidth")

    /// The chat column choices (the page's acpmux chatWidth.ts).
    public nonisolated enum ChatWidth: String, Sendable, CaseIterable, TunableChoice {
        case standard
        case wide
        case wideBlocks

        public var tunableTitle: String {
            switch self {
            case .standard: "Standard"
            case .wide: "Wide"
            case .wideBlocks: "Wide blocks"
            }
        }
    }

    /// Long thoughts fold once done (webviews conversation/ThoughtRow.tsx): a thought taller than
    /// the transcript's view folds to one line that opens to its text. Off keeps every thought in
    /// full (Leo 2026-10-13, #20330) until Leo picks the default. New agent tabs read it.
    public static let foldLongThoughts = Tunable<Bool>.toggle(
        "agentPane.debug.foldLongThoughts", PageTunables.section, "Fold long thoughts in the agent pane",
        help: "A finished thought taller than the transcript folds to one line that opens to its text. New agent tabs.",
        default: false, code: "AgentPaneTunables.foldLongThoughts")

    /// The composer footer's plain look (Claude Code desktop's footer): the model name muted, no
    /// brand mark or mode lock, Plan as accent text; a chip's wash only on hover, focus or an open
    /// menu. It rides the `composer` page event (`plainFooter`, composerSettings.ts); no cmux.json key.
    public static let composerPlainFooter = Tunable<Bool>.toggle(
        "agent.composerPlainFooter", PageTunables.section, "Agent composer: plain footer",
        help: "The composer's model, effort and mode chips draw as plain text until hovered, focused or open.",
        default: false, code: "AgentPaneTunables.composerPlainFooter")

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

    public static var all: [TunableDescriptor] {
        [pageHost.descriptor, chatWidth.descriptor, foldLongThoughts.descriptor, composerPlainFooter.descriptor]
    }
}
