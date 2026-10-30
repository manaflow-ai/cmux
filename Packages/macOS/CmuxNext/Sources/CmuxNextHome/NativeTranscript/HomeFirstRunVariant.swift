#if DEBUG || CMUX_BENCH_HOOKS
import AppKit

/// DEBUG ONLY, exploration: one design variation of the empty Chief conversation's first-run
/// panel (`HomeFirstRunView`), applied over the real hero, intro, starter chips, action rows and
/// Switching card by `debug.home.sidebar_fixture` `first_run_variant` for the Home variations
/// gallery. Copy here is draft copy, not localized: a chosen variant moves into `HomeStrings`.
public struct HomeFirstRunVariant: Sendable {
    /// The panel's parts, in the order the variant stacks them.
    public enum Part: Sendable { case heading, intro, hero, starters, actions, tiles, switchCard }
    /// How the action rows draw.
    public enum RowStyle: Sendable { case card, plain, pill, tall }
    public enum Vertical: Sendable { case center, top, bottom }

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

    // swiftlint:disable line_length
    /// The gallery's variations, V1 to V16 (V0 is the shipping panel, nil).
    public static let all: [HomeFirstRunVariant] = [
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
        HomeFirstRunVariant(number: 11, caption: "Framed card: the whole welcome on one raised card", parts: [.hero, .actions], width: 320, face: 56, framed: true),
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
    // swiftlint:enable line_length

    /// The variation numbered `number` (1...16); nil for any other number (the shipping panel).
    public static func numbered(_ number: Int) -> HomeFirstRunVariant? { all.first { $0.number == number } }
}
#endif
