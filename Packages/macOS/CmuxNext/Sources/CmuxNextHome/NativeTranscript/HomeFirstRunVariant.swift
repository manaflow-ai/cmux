#if DEBUG || CMUX_BENCH_HOOKS
import AppKit

/// DEBUG ONLY, exploration: one design variation of the empty Chief conversation's first-run
/// panel (`HomeFirstRunView`), applied over the real hero, intro, starter chips, action rows and
/// Switching card by `debug.home.sidebar_fixture` `first_run_variant` for the Home variations
/// gallery. Copy here is draft copy, not localized: a chosen variant moves into `HomeStrings`.
public struct HomeFirstRunVariant: Sendable {
    /// The panel's parts, in the order the variant stacks them.
    public enum Part: Sendable { case heading, intro, hero, starters, actions, tiles, switchCard, workspaces }
    /// How the action rows draw.
    public enum RowStyle: Sendable { case card, plain, pill, tall }
    public enum Vertical: Sendable { case center, top, bottom }

    /// The one background the whole Home screen shares in this variant (title bar, sidebar, chat,
    /// compose band, team list): a light and a dark colour and the name the caption gives it.
    public struct Background: Sendable {
        public var name: String
        var light: UInt32
        var dark: UInt32
        /// nil: the shipping look (no override).
        func color(dark isDark: Bool) -> NSColor? {
            guard name != Self.shipping.name else { return nil }
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        static let shipping = Background(name: "shipping (no override)", light: 0, dark: 0)
        static let paper = Background(name: "Paper white #FFFFFF / Ink #1C1C1E", light: 0xFFFFFF, dark: 0x1C1C1E)
        static let messages = Background(name: "Messages gray #F5F5F7 / #232325", light: 0xF5F5F7, dark: 0x232325)
        static let warm = Background(name: "Warm paper #FAF8F4 / #1D1B18", light: 0xFAF8F4, dark: 0x1D1B18)
        static let mist = Background(name: "Blue mist #F3F6FB / Night blue #161A22", light: 0xF3F6FB, dark: 0x161A22)
        static let graphite = Background(name: "Graphite #ECECEE / True black #000000", light: 0xECECEE, dark: 0x000000)
    }

    public var number: Int
    public var caption: String
    var parts: [Part]
    var width: CGFloat = 340
    var leading = false
    var vertical: Vertical = .center
    var rowStyle: RowStyle = .card
    var spacing: CGFloat = 6
    var groupGap: CGFloat = 16
    /// The hero's face side (0: no face) and copy (nil: the shipping copy; "": none).
    var face: CGFloat = 72
    var heroTitle: String?
    var heroBody: String?
    var heroTitleSize: CGFloat?
    /// A small uppercase-free heading over the panel (`Part.heading`).
    var heading: String?
    /// The intro bubble's text (nil: the shipping welcome) and whether it is the sent-blue bubble.
    var intro: String?
    var introBlue = false
    var introWidth: CGFloat?
    var starters: [String] = []
    var starterLook: HomeStarterChips.Look = .wrapped
    /// The action rows: `agent`, `terminal`, `memory`, `pet`, with optional relabels.
    var actions: [String] = ["agent", "terminal", "pet"]
    var actionTitles: [String: String] = [:]
    var memoryTitle = "Bring your memory from Claude Code"
    var tileHeight: CGFloat = 84
    /// The whole panel sits on a raised card.
    var framed = false
    var background: Background = .paper
    /// Round 2: the person's ask, Chief's answer and the workspace cards (`Part.workspaces`).
    var ask: String?
    var reply: String?
    var workspaces: [DebugVariantWorkspacesView.Workspace] = []
    var compactCards = false

    // swiftlint:disable line_length
    /// The gallery's variations, V1 to V16 (V0 is the shipping panel, nil).
    public static let all: [HomeFirstRunVariant] = designs.map { design in
        var variant = design
        guard design.number <= 16 else { return variant }
        let cycle: [Background] = [.paper, .messages, .warm, .mist, .graphite]
        variant.background = cycle[(design.number - 1) % cycle.count]
        return variant
    }

    private static let designs: [HomeFirstRunVariant] = roundOne + roundTwo

    private static let roundOne: [HomeFirstRunVariant] = [
        HomeFirstRunVariant(number: 1, caption: "Quiet: no hero, three plain suggestions just above the field", parts: [.starters], width: 520, leading: true, vertical: .bottom,
                            starters: ["Fix the failing test in my repo", "Start an agent on a new branch", "What can you do?"], starterLook: .plain),
        HomeFirstRunVariant(number: 2, caption: "iMessage thread: Chief's welcome as a blue bubble at the top, chips under it", parts: [.intro, .starters], width: 460, leading: true, vertical: .top,
                            intro: "Hi, I'm Chief. Tell me what you want done and I'll do it or hand it to an agent.", introBlue: true, introWidth: 330,
                            starters: ["Start an agent", "Open a terminal", "What can you do?"]),
        HomeFirstRunVariant(number: 3, caption: "Big hello: large face, one line, nothing else", parts: [.hero], width: 420, face: 120,
                            heroTitle: "Hi, I'm Chief", heroBody: "Tell me what you want done.", heroTitleSize: 28),
        HomeFirstRunVariant(number: 4, caption: "Question first: face, \"What should we work on?\", suggestion chips", parts: [.hero, .starters], width: 440,
                            heroTitle: "What should we work on?", heroBody: "", heroTitleSize: 22,
                            starters: ["Fix a bug", "Review a PR", "Start an agent", "Plan my day"]),
        HomeFirstRunVariant(number: 5, caption: "Rows only: actions and keys, no hero (today minus the face)", parts: [.actions, .switchCard], groupGap: 18),
        HomeFirstRunVariant(number: 6, caption: "Checklist: \"Get started\" steps, left aligned, top", parts: [.heading, .actions], width: 380, leading: true, vertical: .top, rowStyle: .plain,
                            heading: "Get started",
                            actions: ["agent", "terminal", "memory", "pet"],
                            actionTitles: ["agent": "1   Start your first agent", "terminal": "2   Open a terminal", "memory": "3   Bring your memory from Claude Code", "pet": "4   Meet the Chief pet"]),
        HomeFirstRunVariant(number: 7, caption: "Tiles: small face, three big buttons side by side", parts: [.hero, .tiles], width: 480, face: 48,
                            heroTitle: "Your Chief", heroBody: "", actions: ["agent", "terminal", "memory"],
                            actionTitles: ["memory": "Import memory"]),
        HomeFirstRunVariant(number: 8, caption: "Pills: hero, then capsule buttons in a narrow column", parts: [.hero, .actions], width: 260, rowStyle: .pill, spacing: 8, face: 64),
        HomeFirstRunVariant(number: 9, caption: "Dense: everything, small, left aligned at the top (power user)", parts: [.hero, .starters, .actions, .switchCard], width: 300, leading: true, vertical: .top,
                            spacing: 4, groupGap: 10, face: 36, heroTitleSize: 15,
                            starters: ["Help me open a workspace", "Help me start an agent"]),
        HomeFirstRunVariant(number: 10, caption: "Keyboard first: \"Keys to know\" card leads, actions with shortcuts under it", parts: [.heading, .switchCard, .actions], width: 360,
                            heading: "Keys to know"),
        HomeFirstRunVariant(number: 11, caption: "Framed: the whole welcome inside one hairline outline (no card fill)", parts: [.hero, .actions], width: 320, face: 56, framed: true),
        HomeFirstRunVariant(number: 12, caption: "Full welcome: intro bubble, hero, suggestions, actions, keys", parts: [.intro, .hero, .starters, .actions, .switchCard], width: 360, face: 56,
                            starters: ["Help me open a workspace", "Help me start an agent", "Help me choose my next task"]),
        HomeFirstRunVariant(number: 13, caption: "Memory first: bring what Claude Code and ChatGPT know, before anything else", parts: [.hero, .actions], width: 360, rowStyle: .tall, face: 56,
                            heroTitle: "Start where you left off", heroBody: "Chief can read what Claude Code and ChatGPT already know about you and your projects.",
                            actions: ["memory", "agent"], actionTitles: ["agent": "Skip, start an agent"]),
        HomeFirstRunVariant(number: 14, caption: "Team: \"Your team is here\" with the team listed in the sidebar", parts: [.hero, .starters], width: 420, face: 56,
                            heroTitle: "Your team is here", heroBody: "Message a teammate on the left, or ask Chief to do something for all of you.",
                            starters: ["Say hi to the team", "Invite a teammate", "What is everyone working on?"]),
        HomeFirstRunVariant(number: 15, caption: "Focus: collapsed sidebar, one big prompt line, wide chips", parts: [.hero, .starters], width: 600, face: 0,
                            heroTitle: "Ask Chief anything", heroBody: "", heroTitleSize: 32,
                            starters: ["Fix the failing CI on main", "Start three agents on the backlog", "Summarize my open PRs", "Set up a new repo"]),
        HomeFirstRunVariant(number: 16, caption: "Thumb zone: small hero and plain rows, all just above the field", parts: [.hero, .starters, .actions], width: 420, leading: true, vertical: .bottom,
                            rowStyle: .plain, spacing: 2, groupGap: 12, face: 32, heroTitle: "Chief", heroBody: "Type below, or pick one:",
                            heroTitleSize: 15, starters: ["What can you do?", "Start an agent on this repo"], starterLook: .plain),
    ]
    private typealias W = DebugVariantWorkspacesView.Workspace
    private static let landing = W(name: "landing-page", detail: "Claude Code · working · ~/code/site", status: "working", key: "⌘1")
    private static let bugs = [
        W(name: "bug-412-login", detail: "Codex · working · fix sign-in loop", status: "working", key: "⌘1"),
        W(name: "bug-418-crash", detail: "Claude Code · working · crash on resume", status: "working", key: "⌘2"),
        W(name: "bug-421-scroll", detail: "Claude Code · done · PR ready", status: "done", key: "⌘3"),
    ]
    private static let six = bugs + [
        W(name: "api", detail: "Terminal · bun dev", status: "idle", key: "⌘4"),
        W(name: "docs", detail: "Browser · localhost:3000", status: "idle", key: "⌘5"),
        W(name: "release-1.3", detail: "Codex · working · changelog", status: "working", key: "⌘6"),
    ]
    private static let welcome = "Hi, I'm Chief. I can make workspaces, start agents in them and set up cmux for you. What should we work on?"

    private static let roundTwo: [HomeFirstRunVariant] = [
        HomeFirstRunVariant(number: 17, caption: "Empty, hello: CH face, what Chief can do, three starters; no workspaces yet", parts: [.hero, .starters], width: 420, face: 64,
                            heroTitle: "Hi, I'm Chief", heroBody: "I can make workspaces, start agents in them and set up cmux for you.", heroTitleSize: 22,
                            starters: ["Make a workspace for my repo", "Start an agent", "Set up cmux"], background: .paper),
        HomeFirstRunVariant(number: 18, caption: "Empty, first-launch welcome: Chief's first message as a chat bubble, chips under it", parts: [.intro, .starters], width: 460, leading: true, vertical: .top,
                            intro: welcome, introWidth: 340, starters: ["Make my first workspace", "Import my Claude Code memory", "Set up cmux"], background: .messages),
        HomeFirstRunVariant(number: 19, caption: "Empty, checklist: \"Get started\" steps, the first one makes a workspace", parts: [.heading, .actions], width: 380, leading: true, vertical: .top, rowStyle: .plain,
                            heading: "Get started", actions: ["agent", "terminal", "memory"],
                            actionTitles: ["agent": "1   Make your first workspace", "terminal": "2   Open a terminal in it", "memory": "3   Bring your memory from Claude Code"], background: .warm),
        HomeFirstRunVariant(number: 20, caption: "Empty, tiles: small CH face, three big buttons (New workspace, Start an agent, Set up cmux)", parts: [.hero, .tiles], width: 480, face: 48,
                            heroTitle: "Chief", heroBody: "", actions: ["terminal", "agent", "memory"],
                            actionTitles: ["terminal": "New workspace", "agent": "Start an agent", "memory": "Set up cmux"], background: .mist),
        HomeFirstRunVariant(number: 21, caption: "Just made one: your ask, Chief's answer, the new workspace as a card; the sidebar shows it", parts: [.workspaces, .starters], width: 440, leading: true, vertical: .bottom,
                            starters: ["Open landing-page", "Make another"], starterLook: .plain, background: .paper,
                            ask: "Make a workspace for the landing page", reply: "Made landing-page and started Claude Code in it. I'll tell you here when it's done.", workspaces: [landing]),
        HomeFirstRunVariant(number: 22, caption: "Just made three: one ask fans out to three workspaces, one agent each", parts: [.workspaces], width: 460, leading: true, vertical: .bottom,
                            background: .messages,
                            ask: "Start agents on the three open bugs", reply: "Made three workspaces, one agent each. Two are working, one has a PR ready.", workspaces: bugs),
        HomeFirstRunVariant(number: 23, caption: "Just made one, minimal: Chief's answer only, two chips, no card", parts: [.workspaces, .starters], width: 420, leading: true, vertical: .bottom,
                            starters: ["Open landing-page   ⌘1", "Make another"], background: .warm,
                            reply: "Made landing-page with Claude Code in it. It's on the left."),
        HomeFirstRunVariant(number: 24, caption: "Welcome back: small hero, your workspaces as cards, starters", parts: [.hero, .workspaces, .starters], width: 420, face: 40,
                            heroTitle: "Welcome back", heroBody: "", heroTitleSize: 18, starters: ["What changed today?", "Make a workspace"], background: .mist,
                            workspaces: bugs),
        HomeFirstRunVariant(number: 25, caption: "Populated, dense: \"Today\" with six workspaces in compact rows, top left", parts: [.heading, .workspaces], width: 380, leading: true, vertical: .top,
                            heading: "Today", background: .graphite, workspaces: six, compactCards: true),
        HomeFirstRunVariant(number: 26, caption: "Populated, quiet: no hero, plain suggestions above the field; the sidebar carries the workspaces", parts: [.starters], width: 520, leading: true, vertical: .bottom,
                            starters: ["Check on bug-418-crash", "Make a workspace", "What changed today?"], starterLook: .plain, background: .paper),
        HomeFirstRunVariant(number: 27, caption: "Populated, framed: \"3 workspaces running\" and their cards inside one hairline outline", parts: [.hero, .workspaces], width: 360, face: 40,
                            heroTitle: "3 workspaces running", heroBody: "", heroTitleSize: 18, framed: true, background: .messages, workspaces: bugs),
        HomeFirstRunVariant(number: 28, caption: "Populated, question: \"What's next?\" with chips that name your workspaces", parts: [.hero, .starters], width: 460, face: 56,
                            heroTitle: "What's next?", heroBody: "", heroTitleSize: 22,
                            starters: ["Review bug-421-scroll's PR", "Unblock bug-418-crash", "Make a workspace for docs"], background: .warm),
        HomeFirstRunVariant(number: 29, caption: "Team and workspaces: teammates in the list, workspaces in the sidebar, Chief offers both", parts: [.hero, .starters], width: 420, face: 56,
                            heroTitle: "Your team is here", heroBody: "Message a teammate, or ask Chief to make a workspace for all of you.",
                            starters: ["Make a shared workspace", "What is everyone working on?"], background: .mist),
        HomeFirstRunVariant(number: 30, caption: "Busy window: a dozen workspaces, tabs and splits open; Home stays quiet, one line", parts: [.hero, .starters], width: 520, face: 0,
                            heroTitle: "Ask Chief anything", heroBody: "", heroTitleSize: 26,
                            starters: ["Which workspaces need me?", "Close the done ones"], background: .paper),
    ]
    // swiftlint:enable line_length

    /// The variation numbered `number` (1...30); nil for any other number (the shipping panel).
    public static func numbered(_ number: Int) -> HomeFirstRunVariant? { all.first { $0.number == number } }
}
#endif
