import CmuxNextCompat
public import CmuxNextDesign
import CmuxNextPages
import Foundation

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

/// What a folded thought's one line reads (webviews conversation/ThoughtRow.tsx):
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

/// Which done thoughts fold (webviews conversation/ThoughtRow.tsx):
/// `agentPane.debug.thoughtFoldThreshold`. `every` sets nothing on the page.
public nonisolated enum AgentPaneThoughtFoldThreshold: String, Sendable, CaseIterable, TunableChoice {
    /// Every one, to "Thought for 12s" with none of its text inline, as Claude Desktop and Codex
    /// draw it (Leo 2026-10-20).
    case every
    /// Only one taller than the transcript's view, never under 400px (#20948); a shorter one
    /// shows in full after "Thought". With the live viewport on, taller than seven lines.
    case viewport
    /// Only one taller than seven 20px lines, the 140px Codex gives a reasoning trace (#20963).
    case codex

    public var tunableTitle: String {
        switch self {
        case .every: "Every finished thought (default)"
        case .viewport: "Taller than the transcript"
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

/// Harness placements for the model picker. `symbols`, the default, is one row of harness symbols
/// at the top, each name on hover (Leo 2026-10-30: "honestly we had a pretty good thing going with
/// teh symbols of the harneses at the top :("); the others are alternatives (DEV/NIGHTLY).
public nonisolated enum AgentPaneHarnessPlacement: String, Sendable, CaseIterable, TunableChoice {
    case symbols
    case left
    case top
    case compact

    public var tunableTitle: String {
        switch self {
        case .symbols:
            String(localized: "agentPane.harnessPlacement.symbols", defaultValue: "Top row of harness symbols", bundle: .module)
        case .left:
            String(localized: "agentPane.harnessPlacement.left", defaultValue: "Left rail with names", bundle: .module)
        case .top:
            String(localized: "agentPane.harnessPlacement.top", defaultValue: "Top strip with names", bundle: .module)
        case .compact:
            String(localized: "agentPane.harnessPlacement.compact", defaultValue: "Compact left rail", bundle: .module)
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
    /// The agent chat in Chromium (Leo 2026-10-20 spike; on by default since Lawrence asked for every
    /// cmux page in Chromium, 2026-10-21): new agent tabs go on the page host and its page leaves the
    /// ``PageWebKitReason/agentChat`` hold, so it shows in Chromium when `browser.defaultEngine` is
    /// Chromium. A Chromium page is an opaque child window, so window glass does not show through
    /// it. Off keeps the agent chat on WebKit.
    public static let chromium = Tunable<Bool>.toggle(
        "agent.chromium", PageTunables.section, "Agent chat in Chromium (spike)",
        help: "New agent tabs show in Chromium instead of WebKit, on the page host, when the browser engine is Chromium.",
        default: true, code: "AgentPaneTunables.chromium")
    /// Session Info at the right of every agent chat, Chief included (cx-ncc.101; Leo 2026-10-20):
    /// Environment, Context, Connectors, Changes, Servers, Subagents, Background tasks and Outputs,
    /// with a header toggle that shows and hides it. On by default; off brings back the summary card.
    /// It is the shipped Session Info, not a dev-only surface: #26390 switched it off with those, which
    /// put the old summary card back in every build (Leo, 2026-10-31: "omfg we already previouls
    /// yfucking built that shit").
    /// Listed in TunableCatalog on its own line, outside `all`, so it does not churn with that list.
    /// Its key stays `agent.inspector`: it is the saved Debug Settings key, and renaming it would drop a saved choice.
    public static let sessionInfo = Tunable<Bool>.toggle(
        "agent.inspector", PageTunables.section, "Session Info",
        help: "A header toggle opens Session Info at the right of the chat: its environment, context, pull requests, subagents, background tasks and outputs.",
        default: true, code: "AgentPaneTunables.sessionInfo")

    /// Leo 2026-10-15: "Terminal: maybe not a toggle. Clicking the terminal button adds another
    /// terminal on the right each time." On, the chat header's Terminal opens a split on every
    /// click (`AgentChatSplitToggles.open`) instead of toggling the one it opened.
    public static let terminalButtonAdds = Tunable<Bool>.toggle(
        "agentChat.terminalButtonAdds", .panes, "Terminal button adds a terminal",
        help: "Each click of an agent chat's Terminal button opens a new terminal right of the last one and focuses it, instead of closing the terminal it opened.",
        default: false, code: "AgentPaneTunables.terminalButtonAdds")

    /// Leo 2026-10-20, "these buttons are kind of weird": one globe instead of Preview beside Browser.
    /// On (the default), the chat header's Browser opens the chat's local page beside the chat when its
    /// last turns named one, and Preview is not a button of its own. Off: Preview shows as its own
    /// button and Browser always opens a plain browser, as before. Pushed with the header state.
    public static let browserOpensPreview = Tunable<Bool>.toggle(
        "agentChat.browserOpensPreview", .panes, "Browser button opens the chat's page",
        help: "An agent chat's Browser button opens the local page the chat named (its preview) beside the chat, and Preview is not a separate button. Off: separate Preview and Browser buttons.",
        default: true, code: "AgentPaneTunables.browserOpensPreview")

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
    /// beside it, and the palette offers Ask a Side Question… when the gate is on.
    /// On by default; the page reads it from the header state (``AgentPaneHeaderState/sideSessions``).
    public static let sideSessions = Tunable<Bool>.toggle(
        "agentPane.debug.sideSessions", PageTunables.section, "Side sessions (/btw)",
        help: "The composer's /btw opens a read-only side session beside the chat, and the palette offers Ask a Side Question….",
        default: true, code: "AgentPaneTunables.sideSessions")

    /// Thoughts fold once done (webviews conversation/ThoughtRow.tsx): the thoughts
    /// ``thoughtFoldThreshold`` picks fold to one line that opens to their text. On by default (Leo
    /// 2026-10-18, #20963) and then sets nothing on the page; off (`data-fold-long-thoughts="off"`)
    /// keeps every thought in full, as #20330 drew it. New agent tabs read it.
    public static let foldLongThoughts = Tunable<Bool>.toggle(
        "agentPane.debug.foldLongThoughts", PageTunables.section, "Fold finished thoughts in the agent pane",
        help: "A finished thought folds to one line that opens to its text. New agent tabs.",
        default: true, code: "AgentPaneTunables.foldLongThoughts")

    /// A streaming reply grows a whole word at a time, each word fading in (webviews
    /// conversation/RevealedMarkdown.tsx). On by default; off, it grows a character at a time as
    /// before. New agent tabs read it.
    public static let streamWords = Tunable<Bool>.toggle(
        "agentPane.debug.streamWords", PageTunables.section, "Stream replies a word at a time",
        help: "A streaming reply grows by whole words, each fading in. Off: a character at a time. New agent tabs.",
        default: true, code: "AgentPaneTunables.streamWords")

    /// A mouse wheel's notch glides the transcript over the motion scale's standard 180 ms instead
    /// of jumping (webviews agent-session/acpmux/wheelGlide.ts); trackpad scrolling is the engine's
    /// either way. On by default (Leo 2026-10-22: "smoother scrolling in webkit: i mean with a
    /// mouse"); off (`data-wheel-glide="off"`), the wheel scrolls as WebKit does. New agent tabs
    /// read it.
    public static let wheelGlide = Tunable<Bool>.toggle(
        "agentPane.debug.wheelGlide", PageTunables.section, "Smooth mouse wheel in the transcript",
        help: "Each mouse wheel notch glides the transcript instead of jumping. Trackpads are unchanged. New agent tabs.",
        default: true, code: "AgentPaneTunables.wheelGlide")

    /// Which done thoughts fold (``foldLongThoughts``): every one by default (Leo 2026-10-20), or,
    /// as before, only a tall one. New agent tabs read it.
    public static let thoughtFoldThreshold = Tunable<AgentPaneThoughtFoldThreshold>.choice(
        "agentPane.debug.thoughtFoldThreshold", PageTunables.section, "Thought fold",
        help: "Fold every finished thought to Thought for 12s, or only one taller than the transcript (never under 400px) or Codex's seven lines (140px), showing shorter ones in full. With Live thought viewport on, the taller choices fold past 140px. New agent tabs.",
        default: .every, code: "AgentPaneTunables.thoughtFoldThreshold")

    /// What a folded thought's line reads: how long the agent thought, or its first line.
    /// Only a folded thought shows it (``foldLongThoughts``). New agent tabs read it.
    public static let thoughtHeader = Tunable<AgentPaneThoughtHeader>.choice(
        "agentPane.debug.thoughtHeader", PageTunables.section, "Folded thought header",
        help: "A folded thought reads how long the agent thought, or Thought and its first line. New agent tabs.",
        default: .duration, code: "AgentPaneTunables.thoughtHeader")

    /// A long thought streams in a fixed seven-line viewport with its newest line in view, as
    /// Codex's reasoning trace does, then folds once done (``foldLongThoughts``). Off, it shows in
    /// full while it streams. Only applies while ``foldLongThoughts`` is on. New agent tabs read it.
    public static let liveThoughtViewport = Tunable<Bool>.toggle(
        "agentPane.debug.liveThoughtViewport", PageTunables.section, "Live thought viewport",
        help: "While a long thought streams, it holds seven lines with its newest in view, then folds. Needs Fold long thoughts. New agent tabs.",
        default: true, code: "AgentPaneTunables.liveThoughtViewport")

    /// A turn that started or mentioned a local web page gets a preview card under its answer
    /// (webviews conversation/PreviewCard.tsx: the address, Load preview, Open in tab, Open in). Off
    /// by default (Leo 2026-10-20: a mentioned dev server is not worth a card nobody asked for); the
    /// address stays a link in the reply. New agent tabs read it.
    public static let turnPreviewCards = Tunable<Bool>.toggle(
        "agentPane.debug.turnPreviewCards", PageTunables.section, "Local page preview cards in the agent pane",
        help: "A turn that started or mentioned a local web page shows a card under its answer with Load preview. New agent tabs.",
        default: false, code: "AgentPaneTunables.turnPreviewCards")

    /// The top strip's look (webviews composerLocation.css): `default` sets nothing, so the page
    /// draws as before; the others set `data-top-strip` on `<html>`. New agent tabs read it.
    public static let topStripStyle = Tunable<AgentPaneTopStripStyle>.choice(
        "agentPane.debug.topStripStyle", PageTunables.section, "Composer top strip style",
        help: "What stands on the composer's top edge (location strip, queued prompts): today's tab, a separate bump, plain text, or a tray tucked under the card. New agent tabs.",
        default: .default, code: "AgentPaneTunables.topStripStyle")

    /// The answer footer's copy/retry/fork actions (the webview's `turnActionsPlacement`).
    public static let turnActionsPlacement = Tunable<AgentPaneTurnActionsPlacement>.choice(
        "agentPane.debug.turnActionsPlacement", PageTunables.section, "Turn footer actions",
        help: "Place the answer footer's copy, retry and fork actions on the left, under the answer as Claude Code desktop does, or on the right.",
        default: .left, code: "AgentPaneTunables.turnActionsPlacement")

    /// The composer footer's plain look (Claude Code desktop's footer): the model name muted, no
    /// brand mark or mode lock, Plan as accent text; a chip's wash only on hover, focus or an open
    /// menu. It rides the `composer` page event (`plainFooter`, composerSettings.ts); no cmux.json key.
    public static let composerPlainFooter = Tunable<Bool>.toggle(
        "agent.composerPlainFooter", PageTunables.section, "Agent composer: plain footer",
        help: "The composer's model, effort and mode chips draw as plain text until hovered, focused or open.",
        default: true, code: "AgentPaneTunables.composerPlainFooter")

    public static let harnessPlacement = Tunable<AgentPaneHarnessPlacement>.choice(
        "agent.harnessPlacement", PageTunables.section,
        String(localized: "agentPane.harnessPlacement.title", defaultValue: "Model picker harness placement", bundle: .module),
        help: String(localized: "agentPane.harnessPlacement.help",
                     defaultValue: "Compare a named left rail, a wrapping top strip and a compact left rail.", bundle: .module),
        default: .symbols, code: "AgentPaneTunables.harnessPlacement")

    /// Tool runs fold as the Codex desktop app folds them (webviews conversation/turns.ts
    /// `codexRuns`, cx-ncc.108): each finished run is one summary line between the paragraphs
    /// ("Read files, ran commands", "Ran 3 commands") that opens on a click, in a running turn and
    /// in an open "Worked for" alike, and the call in flight is the turn's live line, which each
    /// step replaces in place. Off keeps every call's row. The page gets it with the theme
    /// (`AgentPaneTheme`, `codexToolRuns`), again on each change. On by default (Leo and Lawrence
    /// 2026-10-21: the turn should look and behave like the ChatGPT/Codex app). The earlier "we're
    /// swallowing up a few too many of these" (Leo 2026-10-20) was the run in flight shrinking to
    /// its newest call; finished work now stays one click away and nothing live is hidden.
    public static let codexToolRuns = Tunable<Bool>.toggle(
        "agentPane.debug.codexToolRuns", PageTunables.section, "Codex-style tool runs in the agent pane",
        help: "Each finished run of tool calls is one summary line that opens on a click; the call in flight is the turn's live line.",
        default: true, code: "AgentPaneTunables.codexToolRuns")

    /// Repaints every window when ``codexToolRuns``, ``turnActionsPlacement`` or ``liveLineBelow``
    /// changes, so open agent pages get it with the theme at once (as AppServices.observeBorders
    /// does for ``chatWidth``). The first theme push starts it
    /// (``AgentPaneTheme/values(_:motion:surface:)``).
    @MainActor static func followCodexToolRuns() {
        guard codexToolRunsFollow == nil else { return }
        // task-owner: lives as long as the app; event-driven (Observation)
        codexToolRunsFollow = Task {
            var last = (codexToolRuns.value, turnActionsPlacement.value, liveLineBelow.value)
            for await on in ObservationStream({ (codexToolRuns.value, turnActionsPlacement.value, liveLineBelow.value) })
            where on != last {
                last = on
                ThemeScope.app.store.repaintAll()
            }
        }
    }

    @MainActor private static var codexToolRunsFollow: Task<Void, Never>?

    /// The page's `<html>` `data-*` attributes from these tunables and the Needs you App Store item.
    @MainActor static var documentAttributes: [String: String] {
        attributes(foldLongThoughts: foldLongThoughts.value, topStripStyle: topStripStyle.value,
                   thoughtHeader: thoughtHeader.value, liveThoughtViewport: liveThoughtViewport.value,
                   thoughtFoldThreshold: thoughtFoldThreshold.value,
                   needsYou: needsYouStyle(installed: needsYouInstalled(), debug: needsYou.value),
                   needsYouPill: needsYouPill.value, turnPreviewCards: turnPreviewCards.value,
                   streamWords: streamWords.value, iconFamily: IconFamily.tunable.value,
                   wheelGlide: wheelGlide.value)
    }

    static func attributes(foldLongThoughts: Bool, topStripStyle: AgentPaneTopStripStyle,
                           thoughtHeader: AgentPaneThoughtHeader = .duration,
                           liveThoughtViewport: Bool = true,
                           thoughtFoldThreshold: AgentPaneThoughtFoldThreshold = .every,
                           needsYou: AgentPaneNeedsYouStyle = .pinned, needsYouPill: Bool = true,
                           turnPreviewCards: Bool = false,
                           streamWords: Bool = true, iconFamily: IconFamily = .pack,
                           wheelGlide: Bool = true) -> [String: String] {
        var attributes: [String: String] = [:]
        if needsYou != .pinned { attributes["needs-you"] = needsYou.rawValue }
        if !needsYouPill { attributes["needs-you-pill"] = "off" }
        if !foldLongThoughts { attributes["fold-long-thoughts"] = "off" }
        if thoughtFoldThreshold != .every { attributes["thought-fold-threshold"] = thoughtFoldThreshold.rawValue }
        if thoughtHeader != .duration { attributes["thought-header"] = thoughtHeader.rawValue }
        if !liveThoughtViewport { attributes["live-thought-viewport"] = "off" }
        if topStripStyle != .default { attributes["top-strip"] = topStripStyle.rawValue }
        if turnPreviewCards { attributes["turn-preview-cards"] = "on" }
        if !streamWords { attributes["stream-words"] = "off" }
        // Debug Settings `icons.family`: the page lays the same overlay over its icon pack (iconPack.ts).
        if let overlay = iconFamily.overlay { attributes["icon-family"] = overlay }
        if !wheelGlide { attributes["wheel-glide"] = "off" }
        return attributes
    }

    /// `documentAttributes` as a script run at document start, for the pane's own web view. Names
    /// and values are the fixed lowercase strings above, so they need no escaping.
    @MainActor static var documentScript: String? {
        let attributes = documentAttributes
        guard !attributes.isEmpty else { return nil }
        let sets = attributes.keys.sorted().map { name in
            "document.documentElement.setAttribute('data-\(name)', '\(attributes[name] ?? "")');"
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

    /// Whether Esc on an empty composer stops a running turn only on a second press inside a short
    /// window, as in Claude Code. On (the default), the first press shows "Press Esc again to stop"
    /// in the prompt; off, one press stops the turn. It applies live, as the `composer` event's
    /// `escapeDoublePress` (AgentPaneComposerSetting, webviews composerSettings.ts, escapeStop.ts).
    public static let escapeStopDoublePress = Tunable<Bool>.toggle(
        "agent.escapeStopDoublePress", PageTunables.section, "Esc stops a turn on a double press",
        help: "Esc on an empty composer stops a running turn only when pressed twice in a row. Off, one press stops it.",
        default: true, code: "AgentPaneTunables.escapeStopDoublePress")

    /// The session sidebar's latest-reply hover preview treatment. User layout customization may
    /// still override this choice with `layout.sidebarPreviewVariant` for a prototype.
    public static let sidebarPreviewVariant = Tunable<AgentPaneSidebarPreviewVariant>.choice(
        "agentPane.debug.sidebarPreviewVariant", PageTunables.section, "Sidebar preview variant",
        help: "Visual treatment for the session sidebar's latest-reply hover preview: card, quiet, or outline.",
        default: .card, code: "AgentPaneTunables.sidebarPreviewVariant")

    /// Whether a prompt the daemon dropped with its connection before acpmux took it (an acpmux
    /// restart, a reset socket) goes again on the pane's next connection, under its promptId, so
    /// acpmux runs it at most once (``AgentPanePromptJournal``). Off (the default), the page says
    /// "Not sent" with Retry, as before; the page's recovery for a prompt sent again after its
    /// "Not sent" lands with turning this on.
    public static let lostPromptReplay = Tunable<Bool>.toggle(
        "agentPane.debug.lostPromptReplay", PageTunables.section, "Send again a prompt a dropped connection lost",
        help: "A prompt acpmux never took because its connection dropped goes again on the next connection.",
        default: false, code: "AgentPaneTunables.lostPromptReplay")

    public static var all: [TunableDescriptor] {
        [
            agentPairGuard.descriptor,
            agentPairCap.descriptor,
            agentPairWindow.descriptor,
            chatWidth.descriptor,
            chromium.descriptor,
            codexToolRuns.descriptor,
            composerPlainFooter.descriptor,
            escapeStopDoublePress.descriptor,
            foldLongThoughts.descriptor,
            harnessSwitchInStartedChat.descriptor,
            liveLineBelow.descriptor,
            liveThoughtViewport.descriptor,
            lostPromptReplay.descriptor,
            modelMenu.descriptor,
            harnessPlacement.descriptor,
            needsYou.descriptor,
            needsYouPill.descriptor,
            newTabPicksFollowLinks.descriptor,
            newTabPrivateChatLists.descriptor,
            newTabWidgets.descriptor,
            openOutsideChatsViewOnly.descriptor,
            pageHost.descriptor,
            reasoningSlider.descriptor,
            reasoningSliderStyle.descriptor,
            updatePeersAutomatically.descriptor,
            sessionStatus.descriptor,
            sidebarPreviewVariant.descriptor,
            scrollerFade.descriptor,
            sideSessions.descriptor,
            streamWords.descriptor,
            subagentTray.descriptor,
            suggestedTasks.descriptor,
            systemDictation.descriptor,
            terminalButtonAdds.descriptor,
            browserOpensPreview.descriptor,
            thoughtFoldThreshold.descriptor,
            thoughtHeader.descriptor,
            topStripStyle.descriptor,
            turnPreviewCards.descriptor,
            turnActionsPlacement.descriptor,
            wheelGlide.descriptor,
            agentLinks.descriptor,
            pointerInspector.descriptor,
        ]
    }
}
