import CmuxNextCompat
public import CmuxNextDesign
import CmuxNextPages

/// The look of what stands on the composer card's top edge (the location strip of a new chat, the
/// queued prompts of a started one), for comparing designs: `agentPane.debug.topStripStyle`.
public nonisolated enum AgentPaneTopStripStyle: String, Sendable, CaseIterable, TunableChoice {
    /// Today's: in a chat, a tab of the card's fill on its top edge, sharing its rim; on the New
    /// Tab, the folder and computer as plain text over the card (Cursor's home, Lucas #21133).
    case `default`
    /// A tab a few px above the card in its own closed hairline (#20789).
    case bump
    /// Plain muted text a few px above the card, no fill or rim, on the card's content edge.
    case plain
    /// A filled tray tucked under the card's top edge, its text on the card's content edge.
    case tray

    public var tunableTitle: String {
        switch self {
        case .default: "Default (chat: tab on the card; New Tab: text above it)"
        case .bump: "Bump (tab a few px above, own hairline)"
        case .plain: "Plain (floating text, no chrome)"
        case .tray: "Tray (filled, tucked under the card)"
        }
    }
}

/// How the agent pane draws thoughts, for comparing designs: `agentPane.debug.thoughtStyle`
/// (webviews conversation/thoughtStyle.ts).
public nonisolated enum AgentPaneThoughtStyle: String, Sendable, CaseIterable, TunableChoice {
    /// Today's: a muted "Thought" beside its text; notes between steps draw as replies.
    case plain
    /// A brain and the thought's first line, which opens to "Thoughts" over the whole text; notes
    /// between steps in an open "Worked for" draw the same way (Lucas 2026-10-17).
    case brain

    public var tunableTitle: String {
        switch self {
        case .plain: "Plain (Thought beside its text)"
        case .brain: "Brain (one line that opens to Thoughts)"
        }
    }
}

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
    /// The session side rail beside the chat (cx-ncc.101): Environment, Context and Outputs, with a
    /// header button that shows and hides it. Off until it is promoted to a real setting. Listed in
    /// TunableCatalog on its own line, outside `all`, so it does not churn with that list.
    public static let sessionRail = Tunable<Bool>.toggle(
        "agent.sessionRail", PageTunables.section, "Session side rail",
        help: "A header button opens a rail beside the chat with its environment, context use and changed files.",
        default: false, code: "AgentPaneTunables.sessionRail")

    /// Leo 2026-10-15: "Terminal: maybe not a toggle. Clicking the terminal button adds another
    /// terminal on the right each time." On, the chat header's Terminal opens a split on every
    /// click (`AgentChatSplitToggles.open`) instead of toggling the one it opened.
    public static let terminalButtonAdds = Tunable<Bool>.toggle(
        "agentChat.terminalButtonAdds", .panes, "Terminal button adds a terminal",
        help: "Each click of an agent chat's Terminal button opens a new terminal right of the last one and focuses it, instead of closing the terminal it opened.",
        default: false, code: "AgentPaneTunables.terminalButtonAdds")

    /// Panels open as tabs on the right (Lucas 2026-10-17): with a panel beside the chat, the header's
    /// Terminal and Browser open a tab in that panel's pane instead of another split, and the header
    /// drops its quick-action buttons into "..." (the page's header/ChatHeaderTools.tsx), so the right
    /// side's own tab strip is where new tabs go. Off keeps every split and button as before.
    public static let panelTabs = Tunable<Bool>.toggle(
        "agentChat.panelTabs", .panes, "Panels open as tabs on the right",
        help: "With a panel beside an agent chat, Terminal and Browser add a tab to it instead of another split, and the chat header keeps its tools in its ... menu.",
        default: false, code: "AgentPaneTunables.panelTabs")

    /// The agent chat's side column on Opt-Cmd-B (Lucas 2026-10-17, after T3 Code's surface panel): Toggle
    /// Right Sidebar runs the focused chat's New tab / Hide tabs, so a column of panes opens beside the
    /// chat (a New Tab page whose tiles open a terminal, browser, files or changes there) and hides
    /// again, closing nothing. Off, Toggle Right Sidebar reports that cmux-next has no right sidebar.
    /// Read on every press.
    public static let sideColumn = Tunable<Bool>.toggle(
        "agentChat.sideColumn", .panes, "Opt-Cmd-B opens the chat's side column",
        help: "Toggle Right Sidebar shows and hides a column of panes beside the focused agent chat, starting with a page of tiles for a terminal, browser, files or changes.",
        default: false, code: "AgentPaneTunables.sideColumn")

    /// A chat that shares its pane with other tabs docks left when Files, Changes or Preview opens
    /// beside it, as a chat alone in its pane does (Lucas 2026-10-17): the view lands on its right and
    /// the other tabs stay with it. Off, such a chat keeps its pane and the view takes a new column,
    /// which on a screen without columns filled the window and scrolled the chat out of view.
    public static let dockBesideTabs = Tunable<Bool>.toggle(
        "agentChat.dockBesideTabs", .panes, "Chat docks left beside other tabs",
        help: "Files, Changes or Preview opened from a chat that shares its pane with other tabs docks the chat left and opens on its right, as for a chat alone in its pane.",
        default: false, code: "AgentPaneTunables.dockBesideTabs")

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

    /// Side sessions: the composer's `/btw <question>` opens a read-only side session about the chat
    /// beside it.
    /// Off by default; the page reads it from the header state (``AgentPaneHeaderState/sideSessions``).
    public static let sideSessions = Tunable<Bool>.toggle(
        "agentPane.debug.sideSessions", PageTunables.section, "Side sessions (/btw)",
        help: "The composer's /btw opens a read-only side session beside the chat.",
        default: false, code: "AgentPaneTunables.sideSessions")

    /// Long thoughts fold once done (webviews conversation/ThoughtRow.tsx): a thought taller than
    /// the transcript's view folds to one line that opens to its text. Off keeps every thought in
    /// full (Leo 2026-10-13, #20330) until Leo picks the default. New agent tabs read it.
    public static let foldLongThoughts = Tunable<Bool>.toggle(
        "agentPane.debug.foldLongThoughts", PageTunables.section, "Fold long thoughts in the agent pane",
        help: "A finished thought taller than the transcript folds to one line that opens to its text. New agent tabs.",
        default: false, code: "AgentPaneTunables.foldLongThoughts")

    /// The thoughts' look (webviews conversation/thoughtStyle.ts): `plain` sets nothing, so the
    /// page draws as before; `brain` sets `data-thought-style` on `<html>`. New agent tabs read it.
    public static let thoughtStyle = Tunable<AgentPaneThoughtStyle>.choice(
        "agentPane.debug.thoughtStyle", PageTunables.section, "Thought style",
        help: "Plain: a muted Thought beside its text. Brain: one line with a brain that opens to the whole thought; notes between steps in an open Worked for draw the same way. New agent tabs.",
        default: .plain, code: "AgentPaneTunables.thoughtStyle")

    /// Chat trials also set in layout.json (webviews acpmux/labs.ts). New tabs read these choices
    /// at document start; an explicit layout value wins (Lucas 2026-10-18).
    public static let liveRender = Tunable<Bool>.toggle(
        "agentPane.labs.liveRender", PageTunables.section, "Live render cards in chat",
        help: "Render cards draw inline as they are written and can talk back to the chat. New agent tabs.",
        default: true, code: "AgentPaneTunables.liveRender")
    /// Teach the agent once per session while live render is on (Lucas 2026-10-19).
    public static let renderGuide = Tunable<Bool>.toggle(
        "agentPane.labs.renderGuide", PageTunables.section, "Teach agents to draw in chat",
        help: "Send inline render guidance with the first prompt of each agent session while live render is on. New agent tabs.",
        default: true, code: "AgentPaneTunables.renderGuide")
    /// Native defaults stay scoped to live render frames (Lucas 2026-10-19).
    public static let renderKit = Tunable<Bool>.toggle(
        "agentPane.labs.renderKit", PageTunables.section, "Native styles for chat renders",
        help: "Native controls, charts and follow-ups in live chat renders. New agent tabs.",
        default: true, code: "AgentPaneTunables.renderKit")
    /// Agent preview and wide-table trials share the pane's live layout overrides.
    public static let renderPreview = Tunable<Bool>.toggle(
        "agentPane.labs.renderPreview", PageTunables.section, "Let agents preview chat renders",
        help: "Capture sandboxed renders with diagnostics before showing them. New agent tabs.",
        default: true, code: "AgentPaneTunables.renderPreview")
    public static let renderExpand = Tunable<Bool>.toggle(
        "agentPane.labs.renderExpand", PageTunables.section, "Open chat renders larger",
        help: "A quiet hover control opens a render in a larger dialog. New agent tabs.",
        default: true, code: "AgentPaneTunables.renderExpand")
    public static let tableScroll = Tunable<Bool>.toggle(
        "agentPane.labs.tableScroll", PageTunables.section, "Scroll wide chat tables",
        help: "Keep wide tables within the reply column. New agent tabs.",
        default: true, code: "AgentPaneTunables.tableScroll")
    public static let contextMeter = Tunable<Bool>.toggle(
        "agentPane.labs.contextMeter", PageTunables.section, "Context ring beside the model",
        help: "A ring beside the model shows context use and opens its token details. New agent tabs.",
        default: false, code: "AgentPaneTunables.contextMeter")
    public static let promptCollapse = Tunable<Bool>.toggle(
        "agentPane.labs.promptCollapse", PageTunables.section, "Fold long prompts",
        help: "Long prompts fold to eight lines and open for Find. New agent tabs.",
        default: false, code: "AgentPaneTunables.promptCollapse")
    public static let messageTimes = Tunable<Bool>.toggle(
        "agentPane.labs.messageTimes", PageTunables.section, "Prompt send times on hover",
        help: "Prompts show their send time on hover or focus. New agent tabs.",
        default: false, code: "AgentPaneTunables.messageTimes")
    public static let codeWrap = Tunable<Bool>.toggle(
        "agentPane.labs.codeWrap", PageTunables.section, "One wrap choice for all code blocks",
        help: "One remembered wrap choice applies to every code block in the pane. New agent tabs.",
        default: false, code: "AgentPaneTunables.codeWrap")
    public static let planProgress = Tunable<Bool>.toggle(
        "agentPane.labs.planProgress", PageTunables.section, "Plan progress above the composer",
        help: "The running plan's current step stays above the composer. New agent tabs.",
        default: false, code: "AgentPaneTunables.planProgress")
    public static let shortcutsHelp = Tunable<Bool>.toggle(
        "agentPane.labs.shortcutsHelp", PageTunables.section, "Keyboard shortcuts in the chat menu",
        help: "The chat menu shows the keyboard shortcuts available in the pane. New agent tabs.",
        default: false, code: "AgentPaneTunables.shortcutsHelp")

    static let labTunables: [String: Tunable<Bool>] = [
        "live-render": liveRender, "render-guide": renderGuide, "render-kit": renderKit, "render-preview": renderPreview, "render-expand": renderExpand, "table-scroll": tableScroll, "context-meter": contextMeter, "prompt-collapse": promptCollapse,
        "message-times": messageTimes, "code-wrap": codeWrap, "plan-progress": planProgress,
        "shortcuts-help": shortcutsHelp
    ]

    /// The top strip's look (webviews composerLocation.css): `default` sets nothing, so the page
    /// draws as before; the others set `data-top-strip` on `<html>`. New agent tabs read it.
    public static let topStripStyle = Tunable<AgentPaneTopStripStyle>.choice(
        "agentPane.debug.topStripStyle", PageTunables.section, "Composer top strip style",
        help: "What stands on the composer's top edge (location strip, queued prompts): today's tab, a separate bump, plain text, or a tray tucked under the card. New agent tabs.",
        default: .default, code: "AgentPaneTunables.topStripStyle")

    /// Tool runs fold as the Codex desktop app folds them while a turn runs (webviews
    /// conversation/turns.ts `codexRuns`, cx-ncc.108): the run in flight is one line naming its
    /// newest call, and a run any later row follows settles into its summary line. Off keeps every
    /// call's row until Leo picks the default. The page gets it with the theme (`AgentPaneTheme`,
    /// `codexToolRuns`), again on each change.
    public static let codexToolRuns = Tunable<Bool>.toggle(
        "agentPane.debug.codexToolRuns", PageTunables.section, "Codex-style tool runs in the agent pane",
        help: "While a turn runs, each run of tool calls is one line: the newest call, then a summary once text follows.",
        default: false, code: "AgentPaneTunables.codexToolRuns")

    /// Repaints every window when ``codexToolRuns`` changes, so open agent pages get it with the
    /// theme at once (as AppServices.observeBorders does for ``chatWidth``). The first theme push
    /// starts it (``AgentPaneTheme/values(_:motion:surface:)``).
    @MainActor static func followCodexToolRuns() {
        guard codexToolRunsFollow == nil else { return }
        // task-owner: lives as long as the app; event-driven (Observation)
        codexToolRunsFollow = Task {
            var last = codexToolRuns.value
            for await on in ObservationStream({ codexToolRuns.value }) where on != last {
                last = on
                ThemeStore.shared.repaintAll()
            }
        }
    }

    @MainActor private static var codexToolRunsFollow: Task<Void, Never>?

    /// The page's `<html>` `data-*` attributes from these tunables.
    static var documentAttributes: [String: String] {
        attributes(
            foldLongThoughts: foldLongThoughts.value, topStripStyle: topStripStyle.value,
            thoughtStyle: thoughtStyle.value, labs: labTunables.mapValues { $0.value })
    }

    static func attributes(
        foldLongThoughts: Bool, topStripStyle: AgentPaneTopStripStyle, thoughtStyle: AgentPaneThoughtStyle = .plain,
        labs: [String: Bool] = [:]
    ) -> [String: String] {
        var attributes: [String: String] = [:]
        if foldLongThoughts { attributes["fold-long-thoughts"] = "on" }
        if topStripStyle != .default { attributes["top-strip"] = topStripStyle.rawValue }
        if thoughtStyle != .plain { attributes["thought-style"] = thoughtStyle.rawValue }
        for (name, tunable) in labTunables {
            attributes["lab-\(name)"] = (labs[name] ?? tunable.defaultValue) ? "on" : "off"
        }
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

    /// The composer's reasoning menu draws a stepped slider from Faster to Smarter instead of its
    /// list of levels (an opt-in look, off by default). Unlike the fold above it applies live: it reaches every
    /// agent page as the `composer` event's `reasoningSlider` (AgentPaneComposerSetting, webviews composerSettings.ts).
    public static let reasoningSlider = Tunable<Bool>.toggle(
        "agent.reasoningSlider", PageTunables.section, "Reasoning slider in the composer",
        help: "The composer's reasoning menu shows a slider from Faster to Smarter instead of the list of levels.",
        default: false, code: "AgentPaneTunables.reasoningSlider")

    public static var all: [TunableDescriptor] { [pageHost.descriptor, chatWidth.descriptor, foldLongThoughts.descriptor, thoughtStyle.descriptor, liveRender.descriptor, renderGuide.descriptor, renderKit.descriptor, renderPreview.descriptor, renderExpand.descriptor, tableScroll.descriptor, contextMeter.descriptor, promptCollapse.descriptor, messageTimes.descriptor, codeWrap.descriptor, planProgress.descriptor, shortcutsHelp.descriptor, topStripStyle.descriptor, codexToolRuns.descriptor, terminalButtonAdds.descriptor, panelTabs.descriptor, sideColumn.descriptor, dockBesideTabs.descriptor, suggestedTasks.descriptor, sideSessions.descriptor, reasoningSlider.descriptor] }
}
