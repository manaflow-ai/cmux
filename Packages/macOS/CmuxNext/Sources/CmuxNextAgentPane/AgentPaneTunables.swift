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

/// What a folded long thought's one line reads (webviews conversation/ThoughtRow.tsx):
/// `agentPane.debug.thoughtHeader`. `duration` sets nothing on the page.
public nonisolated enum AgentPaneThoughtHeader: String, Sendable, CaseIterable, TunableChoice {
    /// "Thought for 12s", as Codex's reasoning trace reads once it ends (#20963).
    case duration
    /// "Thought", then the thought's first line (#20948).
    case preview

    public var tunableTitle: String {
        switch self {
        case .duration: "Thought for 12s (default)"
        case .preview: "Thought, then its first line"
        }
    }
}

/// How tall a done thought must be to fold (webviews conversation/ThoughtRow.tsx):
/// `agentPane.debug.thoughtFoldThreshold`. `viewport` sets nothing on the page.
public nonisolated enum AgentPaneThoughtFoldThreshold: String, Sendable, CaseIterable, TunableChoice {
    /// Taller than the transcript's view, never under 400px (#20948).
    case viewport
    /// Taller than seven 20px lines, the 140px Codex gives a reasoning trace (#20963).
    case codex

    public var tunableTitle: String {
        switch self {
        case .viewport: "Taller than the transcript (default)"
        case .codex: "Taller than seven lines (Codex)"
        }
    }
}

/// Where the quiet answer-footer actions sit under a completed turn.
public nonisolated enum AgentPaneTurnActionsPlacement: String, Sendable, CaseIterable, TunableChoice {
    case right
    case left

    public var tunableTitle: String {
        switch self {
        case .right: "Right (default)"
        case .left: "Left"
        }
    }
}

/// Visual treatment of the opt-in reasoning slider. The default keeps the current tokenized
/// accent thumb; `minimal` is a quieter outlined treatment for comparing composer density.
public nonisolated enum AgentPaneReasoningSliderStyle: String, Sendable, CaseIterable, TunableChoice {
    case accent
    case minimal

    public var tunableTitle: String {
        switch self {
        case .accent: "Accent (current)"
        case .minimal: "Minimal (quiet fill, outlined thumb)"
        }
    }
}

/// What a click on the composer's model chip opens. `compact` is the short Claude Code style menu
/// (numbered models, Effort, Account, More models); `full` opens the harness rail and search at once.
public nonisolated enum AgentPaneModelMenuStyle: String, Sendable, CaseIterable, TunableChoice {
    case compact
    case full

    public var tunableTitle: String {
        switch self {
        case .compact: "Compact (default)"
        case .full: "Full picker (harness rail and search)"
        }
    }
}

/// Visual treatments for the session sidebar's latest-reply hover preview.
public nonisolated enum AgentPaneSidebarPreviewVariant: String, Sendable, CaseIterable, TunableChoice {
    /// The elevated card used by the current sidebar.
    case card
    /// A quieter, flatter preview card.
    case quiet
    /// A preview card distinguished by an outline instead of elevation.
    case outline

    public var tunableTitle: String {
        switch self {
        case .card: "Card (current)"
        case .quiet: "Quiet (flatter)"
        case .outline: "Outline (rim, no shadow)"
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

    /// Claude Code desktop's in-session status in an agent chat: the live plan card and the recap
    /// card. Off by default; each open agent page follows a change (``AgentPaneView/sessionStatus``).
    public static let sessionStatus = Tunable<Bool>.toggle(
        "agent.sessionStatus", PageTunables.section, "In-session status (plan card, recap card)",
        help: "Agent chats show the live plan card and the recap card.",
        default: false, code: "AgentPaneTunables.sessionStatus")

    /// Side sessions: the composer's `/btw <question>` opens a read-only side session about the chat
    /// beside it.
    /// Off by default; the page reads it from the header state (``AgentPaneHeaderState/sideSessions``).
    public static let sideSessions = Tunable<Bool>.toggle(
        "agentPane.debug.sideSessions", PageTunables.section, "Side sessions (/btw)",
        help: "The composer's /btw opens a read-only side session beside the chat.",
        default: false, code: "AgentPaneTunables.sideSessions")

    /// Long thoughts fold once done (webviews conversation/ThoughtRow.tsx): a thought taller than
    /// ``thoughtFoldThreshold`` folds to one line that opens to its text. On by default (Leo
    /// 2026-10-18, #20963); off keeps every thought in full, as #20330 drew it. New agent tabs read it.
    public static let foldLongThoughts = Tunable<Bool>.toggle(
        "agentPane.debug.foldLongThoughts", PageTunables.section, "Fold long thoughts in the agent pane",
        help: "A finished long thought folds to one line that opens to its text. New agent tabs.",
        default: true, code: "AgentPaneTunables.foldLongThoughts")

    /// How tall a thought must be to fold (``foldLongThoughts``) while ``liveThoughtViewport`` is
    /// off. With the live viewport on, a thought it clipped always folds once done (140px), so
    /// nothing grows after it streams. New agent tabs read it.
    public static let thoughtFoldThreshold = Tunable<AgentPaneThoughtFoldThreshold>.choice(
        "agentPane.debug.thoughtFoldThreshold", PageTunables.section, "Long thought fold threshold",
        help: "With Live thought viewport off: fold a finished thought taller than the transcript (never under 400px), or taller than Codex's seven lines (140px). With it on, thoughts fold past 140px. New agent tabs.",
        default: .viewport, code: "AgentPaneTunables.thoughtFoldThreshold")

    /// What a folded long thought's line reads: how long the agent thought, or its first line.
    /// Only a folded thought shows it (``foldLongThoughts``). New agent tabs read it.
    public static let thoughtHeader = Tunable<AgentPaneThoughtHeader>.choice(
        "agentPane.debug.thoughtHeader", PageTunables.section, "Folded thought header",
        help: "A folded long thought reads how long the agent thought, or Thought and its first line. New agent tabs.",
        default: .duration, code: "AgentPaneTunables.thoughtHeader")

    /// A long thought streams in a fixed seven-line viewport with its newest line in view, as
    /// Codex's reasoning trace does, then folds once done (``foldLongThoughts``). Off, it shows in
    /// full while it streams. Only applies while ``foldLongThoughts`` is on. New agent tabs read it.
    public static let liveThoughtViewport = Tunable<Bool>.toggle(
        "agentPane.debug.liveThoughtViewport", PageTunables.section, "Live thought viewport",
        help: "While a long thought streams, it holds seven lines with its newest in view, then folds. Needs Fold long thoughts. New agent tabs.",
        default: true, code: "AgentPaneTunables.liveThoughtViewport")

    /// The top strip's look (webviews composerLocation.css): `default` sets nothing, so the page
    /// draws as before; the others set `data-top-strip` on `<html>`. New agent tabs read it.
    public static let topStripStyle = Tunable<AgentPaneTopStripStyle>.choice(
        "agentPane.debug.topStripStyle", PageTunables.section, "Composer top strip style",
        help: "What stands on the composer's top edge (location strip, queued prompts): today's tab, a separate bump, plain text, or a tray tucked under the card. New agent tabs.",
        default: .default, code: "AgentPaneTunables.topStripStyle")

    /// The answer footer's copy/retry/fork actions (the webview's `turnActionsPlacement`).
    public static let turnActionsPlacement = Tunable<AgentPaneTurnActionsPlacement>.choice(
        "agentPane.debug.turnActionsPlacement", PageTunables.section, "Turn footer actions",
        help: "Place the answer footer's copy, retry and fork actions on the left or right.",
        default: .right, code: "AgentPaneTunables.turnActionsPlacement")

    /// The composer footer's plain look (Claude Code desktop's footer): the model name muted, no
    /// brand mark or mode lock, Plan as accent text; a chip's wash only on hover, focus or an open
    /// menu. It rides the `composer` page event (`plainFooter`, composerSettings.ts); no cmux.json key.
    public static let composerPlainFooter = Tunable<Bool>.toggle(
        "agent.composerPlainFooter", PageTunables.section, "Agent composer: plain footer",
        help: "The composer's model, effort and mode chips draw as plain text until hovered, focused or open.",
        default: true, code: "AgentPaneTunables.composerPlainFooter")

    /// Tool runs fold as the Codex desktop app folds them while a turn runs (webviews
    /// conversation/turns.ts `codexRuns`, cx-ncc.108): the run in flight is one line naming its
    /// newest call, and a run any later row follows settles into its summary line. Off keeps every
    /// call's row. The page gets it with the theme (`AgentPaneTheme`, `codexToolRuns`), again on
    /// each change. The Debug toggle remains available for comparing the ungrouped presentation.
    public static let codexToolRuns = Tunable<Bool>.toggle(
        "agentPane.debug.codexToolRuns", PageTunables.section, "Codex-style tool runs in the agent pane",
        help: "While a turn runs, each run of tool calls is one line: the newest call, then a summary once text follows.",
        default: true, code: "AgentPaneTunables.codexToolRuns")

    /// Repaints every window when ``codexToolRuns`` changes, so open agent pages get it with the
    /// theme at once (as AppServices.observeBorders does for ``chatWidth``). The first theme push
    /// starts it (``AgentPaneTheme/values(_:motion:surface:)``).
    @MainActor static func followCodexToolRuns() {
        guard codexToolRunsFollow == nil else { return }
        // task-owner: lives as long as the app; event-driven (Observation)
        codexToolRunsFollow = Task {
            var last = (codexToolRuns.value, turnActionsPlacement.value)
            for await on in ObservationStream({ (codexToolRuns.value, turnActionsPlacement.value) }) where on != last {
                last = on
                ThemeStore.shared.repaintAll()
            }
        }
    }

    @MainActor private static var codexToolRunsFollow: Task<Void, Never>?

    /// The page's `<html>` `data-*` attributes from these tunables.
    static var documentAttributes: [String: String] {
        attributes(foldLongThoughts: foldLongThoughts.value, topStripStyle: topStripStyle.value,
                   thoughtHeader: thoughtHeader.value, liveThoughtViewport: liveThoughtViewport.value,
                   thoughtFoldThreshold: thoughtFoldThreshold.value)
    }

    static func attributes(foldLongThoughts: Bool, topStripStyle: AgentPaneTopStripStyle,
                           thoughtHeader: AgentPaneThoughtHeader = .duration,
                           liveThoughtViewport: Bool = true,
                           thoughtFoldThreshold: AgentPaneThoughtFoldThreshold = .viewport) -> [String: String] {
        var attributes: [String: String] = [:]
        if foldLongThoughts { attributes["fold-long-thoughts"] = "on" }
        if thoughtFoldThreshold != .viewport { attributes["thought-fold-threshold"] = thoughtFoldThreshold.rawValue }
        if thoughtHeader != .duration { attributes["thought-header"] = thoughtHeader.rawValue }
        if !liveThoughtViewport { attributes["live-thought-viewport"] = "off" }
        if topStripStyle != .default { attributes["top-strip"] = topStripStyle.rawValue }
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

    /// The slider treatment to compare while `reasoningSlider` is on. The default is today's
    /// tokenized accent thumb; this remains a Debug Settings choice and never changes the
    /// slider's availability.
    public static let reasoningSliderStyle = Tunable<AgentPaneReasoningSliderStyle>.choice(
        "agent.reasoningSliderStyle", PageTunables.section, "Reasoning slider style",
        help: "Visual treatment for the opt-in reasoning slider: today's accent treatment or a quieter outlined thumb.",
        default: .accent, code: "AgentPaneTunables.reasoningSliderStyle")

    /// What the composer's model chip opens. It applies live, as the `composer` event's
    /// `modelMenu` (AgentPaneComposerSetting, webviews composerSettings.ts).
    public static let modelMenu = Tunable<AgentPaneModelMenuStyle>.choice(
        "agent.modelMenu", PageTunables.section, "Composer model menu",
        help: "Compact: a short menu of numbered models with Effort, Account and More models. Full: the harness rail and search.",
        default: .compact, code: "AgentPaneTunables.modelMenu")

    /// Whether a chat that has a message can still switch harness from its model menu. Off (the
    /// default), its harness is fixed, as in Claude Code: the menu lists that harness's models alone,
    /// with no harness rail and no Add harness…. It applies live, as the `composer` event's
    /// `harnessSwitch` (AgentPaneComposerSetting, webviews composerSettings.ts).
    public static let harnessSwitchInStartedChat = Tunable<Bool>.toggle(
        "agent.harnessSwitchInStartedChat", PageTunables.section, "Allow switching harness in a started chat",
        help: "A chat with a message keeps the model menu's harness rail and Add harness…, and a pick in another harness starts a new chat there.",
        default: false, code: "AgentPaneTunables.harnessSwitchInStartedChat")

    /// The session sidebar's latest-reply hover preview treatment. User layout customization may
    /// still override this choice with `layout.sidebarPreviewVariant` for a prototype.
    public static let sidebarPreviewVariant = Tunable<AgentPaneSidebarPreviewVariant>.choice(
        "agentPane.debug.sidebarPreviewVariant", PageTunables.section, "Sidebar preview variant",
        help: "Visual treatment for the session sidebar's latest-reply hover preview: card, quiet, or outline.",
        default: .card, code: "AgentPaneTunables.sidebarPreviewVariant")

    public static var all: [TunableDescriptor] {
        [
            chatWidth.descriptor,
            codexToolRuns.descriptor,
            composerPlainFooter.descriptor,
            foldLongThoughts.descriptor,
            harnessSwitchInStartedChat.descriptor,
            liveThoughtViewport.descriptor,
            modelMenu.descriptor,
            newTabWidgets.descriptor,
            pageHost.descriptor,
            reasoningSlider.descriptor,
            reasoningSliderStyle.descriptor,
            sessionStatus.descriptor,
            sidebarPreviewVariant.descriptor,
            sideSessions.descriptor,
            suggestedTasks.descriptor,
            terminalButtonAdds.descriptor,
            thoughtFoldThreshold.descriptor,
            thoughtHeader.descriptor,
            topStripStyle.descriptor,
            turnActionsPlacement.descriptor,
        ]
    }
}
