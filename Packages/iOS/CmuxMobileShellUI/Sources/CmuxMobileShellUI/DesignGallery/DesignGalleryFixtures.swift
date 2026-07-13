#if DEBUG
/// The lifecycle state of an agent represented in gallery fixture data.
enum GalleryAgentState: CaseIterable {
    case needsYou
    case running
    case done
    case failed
    case idle
}

/// A static workspace row shared by every candidate's hub screen.
struct GalleryWorkspaceFixture: Identifiable {
    let id: Int
    let name: String
    let branch: String
    let agentName: String
    let state: GalleryAgentState
    let elapsedText: String
    let absoluteTimeText: String
    let detailText: String
    let pendingQuestion: String?
}

/// A terminal transcript line shared by every candidate's session screen.
struct GalleryTerminalLine: Identifiable {
    /// The semantic color role a candidate maps into its own palette.
    enum Tone {
        case plain
        case dim
        case accent
        case success
        case warning
        case error
    }

    let id: Int
    let text: String
    let tone: Tone
}

/// A conversation item shared by every candidate's chat screen.
struct GalleryChatEntry: Identifiable {
    /// The participant or presentation role of a fixture conversation item.
    enum Role {
        case user
        case agent
        case tool
        case approval
    }

    let id: Int
    let role: Role
    let text: String
    let timeText: String
    let toolCommand: String?
    let toolOutput: String?
    let question: String?
}

/// A dated group in the gallery's shared activity feed.
struct GalleryActivityDay {
    let dayLabel: String
    let entries: [GalleryActivityEntry]
}

/// A single event in the gallery's shared activity feed.
struct GalleryActivityEntry: Identifiable {
    let id: Int
    let timeText: String
    let state: GalleryAgentState
    let text: String
    let unread: Bool
}

/// Static account and preference values shared by candidate settings screens.
struct GallerySettingsFixture {
    let accountEmail: String
    let pairedMacName: String
    let pairedMacStatus: String
    let appVersion: String
    let notificationsEnabled: Bool
    let terminalFontSize: String
}

/// Shared static data rendered by every candidate design system.
struct DesignGalleryFixtures {
    static let workspaces: [GalleryWorkspaceFixture] = [
        GalleryWorkspaceFixture(
            id: 1,
            name: "cmux",
            branch: "feat-ios-design-gallery",
            agentName: "Claude",
            state: .needsYou,
            elapsedText: "2m",
            absoluteTimeText: "14:32",
            detailText: "Proposed a 4-system gallery plan",
            pendingQuestion: "Plan adds 24 screens behind the debug menu. Approve?"
        ),
        GalleryWorkspaceFixture(
            id: 2,
            name: "cmux",
            branch: "fix-sidebar-ports",
            agentName: "Codex",
            state: .running,
            elapsedText: "12m",
            absoluteTimeText: "14:22",
            detailText: "Running tests: 214 of 356 passed",
            pendingQuestion: nil
        ),
        GalleryWorkspaceFixture(
            id: 3,
            name: "zed",
            branch: "ghostty-pane-resize",
            agentName: "Claude",
            state: .running,
            elapsedText: "4m",
            absoluteTimeText: "14:30",
            detailText: "Editing crates/terminal_view/src/split.rs",
            pendingQuestion: nil
        ),
        GalleryWorkspaceFixture(
            id: 4,
            name: "web",
            branch: "pricing-page-copy",
            agentName: "Codex",
            state: .done,
            elapsedText: "1h",
            absoluteTimeText: "13:31",
            detailText: "PR #7841 opened, CI green",
            pendingQuestion: nil
        ),
        GalleryWorkspaceFixture(
            id: 5,
            name: "cmux",
            branch: "issue-7691-port-collision",
            agentName: "Claude",
            state: .failed,
            elapsedText: "3h",
            absoluteTimeText: "11:12",
            detailText: "Build failed: linker error in GhosttyKit",
            pendingQuestion: nil
        ),
        GalleryWorkspaceFixture(
            id: 6,
            name: "dotfiles",
            branch: "main",
            agentName: "Codex",
            state: .idle,
            elapsedText: "2d",
            absoluteTimeText: "Jul 11",
            detailText: "No activity",
            pendingQuestion: nil
        ),
    ]

    static let terminalLines: [GalleryTerminalLine] = [
        GalleryTerminalLine(id: 1, text: "$ ./scripts/reload.sh --tag dsgal", tone: .accent),
        GalleryTerminalLine(id: 2, text: "Resolving Swift package dependencies", tone: .dim),
        GalleryTerminalLine(id: 3, text: "[1/8] Compiling CmuxMobileSupport", tone: .dim),
        GalleryTerminalLine(id: 4, text: "[2/8] Compiling CmuxMobileShell", tone: .dim),
        GalleryTerminalLine(id: 5, text: "warning: cached module was built with an older SDK", tone: .warning),
        GalleryTerminalLine(id: 6, text: "[3/8] Compiling CmuxMobileShellUI", tone: .plain),
        GalleryTerminalLine(id: 7, text: "error: dependency scan failed for MobileTerminalKit", tone: .error),
        GalleryTerminalLine(id: 8, text: "Retrying dependency scan with a clean module cache", tone: .dim),
        GalleryTerminalLine(id: 9, text: "[4/8] Compiling CmuxMobileTerminalKit", tone: .plain),
        GalleryTerminalLine(id: 10, text: "[5/8] Linking cmux DEV dsgal", tone: .dim),
        GalleryTerminalLine(id: 11, text: "[6/8] Running CmuxMobileShellUITests", tone: .dim),
        GalleryTerminalLine(id: 12, text: "Test Suite Passed: 42 tests, 0 failures", tone: .success),
        GalleryTerminalLine(id: 13, text: "[8/8] Signing cmux DEV dsgal.app", tone: .dim),
        GalleryTerminalLine(id: 14, text: "Build succeeded", tone: .success),
    ]

    static let chatEntries: [GalleryChatEntry] = [
        GalleryChatEntry(
            id: 1,
            role: .user,
            text: "Fix the sidebar port flicker and add a regression test",
            timeText: "14:20",
            toolCommand: nil,
            toolOutput: nil,
            question: nil
        ),
        GalleryChatEntry(
            id: 2,
            role: .agent,
            text: "I’ll trace the shared port-status update path and reproduce the stale scan transition. Then I’ll add behavior-level coverage before applying the fix.",
            timeText: "14:21",
            toolCommand: nil,
            toolOutput: nil,
            question: nil
        ),
        GalleryChatEntry(
            id: 3,
            role: .tool,
            text: "Build and test",
            timeText: "14:28",
            toolCommand: "./scripts/reload.sh --tag sbport",
            toolOutput: "Compiling CmuxMobileShellUI\nTest Suite Passed: 18 tests, 0 failures\nBuild succeeded",
            question: nil
        ),
        GalleryChatEntry(
            id: 4,
            role: .agent,
            text: "Tests pass. One design question remains.",
            timeText: "14:30",
            toolCommand: nil,
            toolOutput: nil,
            question: nil
        ),
        GalleryChatEntry(
            id: 5,
            role: .approval,
            text: "",
            timeText: "14:31",
            toolCommand: nil,
            toolOutput: nil,
            question: "Should the port badge hide when the scan is stale, or show the last-known port dimmed?"
        ),
    ]

    static let approvalActions = ["Approve", "Deny"]

    static let activityDays: [GalleryActivityDay] = [
        GalleryActivityDay(
            dayLabel: "Today",
            entries: [
                GalleryActivityEntry(
                    id: 1,
                    timeText: "14:32",
                    state: .needsYou,
                    text: "Claude needs your input on cmux",
                    unread: true
                ),
                GalleryActivityEntry(
                    id: 2,
                    timeText: "14:27",
                    state: .done,
                    text: "CI green on PR #7952",
                    unread: true
                ),
                GalleryActivityEntry(
                    id: 3,
                    timeText: "13:31",
                    state: .done,
                    text: "Codex finished pricing-page-copy",
                    unread: false
                ),
                GalleryActivityEntry(
                    id: 4,
                    timeText: "11:12",
                    state: .failed,
                    text: "Build failed on issue-7691",
                    unread: true
                ),
                GalleryActivityEntry(
                    id: 5,
                    timeText: "10:48",
                    state: .running,
                    text: "Claude is running tests on ghostty-pane-resize",
                    unread: false
                ),
            ]
        ),
        GalleryActivityDay(
            dayLabel: "Yesterday",
            entries: [
                GalleryActivityEntry(
                    id: 6,
                    timeText: "18:04",
                    state: .running,
                    text: "Codex started sidebar performance profiling",
                    unread: false
                ),
                GalleryActivityEntry(
                    id: 7,
                    timeText: "16:19",
                    state: .idle,
                    text: "dotfiles has no recent agent activity",
                    unread: false
                ),
                GalleryActivityEntry(
                    id: 8,
                    timeText: "09:42",
                    state: .done,
                    text: "Claude completed terminal input cleanup",
                    unread: false
                ),
            ]
        ),
    ]

    static let settings = GallerySettingsFixture(
        accountEmail: "aziz@manaflow.ai",
        pairedMacName: "Aziz's MacBook Pro",
        pairedMacStatus: "Connected · Tailscale",
        appVersion: "1.4.2 (890)",
        notificationsEnabled: true,
        terminalFontSize: "13"
    )
}
#endif
