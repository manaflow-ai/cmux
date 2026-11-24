import AppKit
import CmuxNextDesign
import CmuxNextPages
import CmuxNextWakeups

/// When to ask for a GitHub star, t3code's rule (apps/web/src/components/GitHubStarPrompt.tsx): count each
/// prompt the person sends; after more than five, ask once per session until dismissed, unless their
/// GitHub account already starred the repo. Separate keys, so a count written by another window can never
/// undo a dismissal.
public nonisolated struct GitHubStarPromptRule: Sendable {
    static let promptsBeforeAsking = 5
    static let sentKey = "cmux.githubStarPrompt.sent"
    static let dismissedKey = "cmux.githubStarPrompt.dismissed"

    /// Counts a sent prompt and says whether this one may start the ask.
    public static func countPrompt(in defaults: UserDefaults) -> Bool {
        if defaults.bool(forKey: dismissedKey) { return false }
        let sent = defaults.integer(forKey: sentKey) + 1
        defaults.set(sent, forKey: sentKey)
        return sent > promptsBeforeAsking
    }

    /// Whether to ask now: another window may have dismissed it during the check or the idle wait.
    public static func stillWanted(in defaults: UserDefaults) -> Bool { !defaults.bool(forKey: dismissedKey) }

    public static func dismiss(in defaults: UserDefaults) { defaults.set(true, forKey: dismissedKey) }
}

public extension Notification.Name {
    /// Posted when the person sends a prompt in a chat (AgentPaneUserGestures); the star ask counts it.
    static let cmuxPromptSent = Notification.Name("cmux.next.prompt-sent")
}

/// "Enjoying cmux? Give us a star on GitHub to let us know!", bottom-left, until closed. Star on GitHub
/// stars in place through the person's `gh` sign-in and thanks them; without one it opens the repo.
/// Every close (both buttons, the X) saves the dismissal.
@MainActor
public final class GitHubStarPrompt {
    static let repository = "manaflow-ai/cmux"
    static let idle: Duration = .seconds(30)

    private let defaults: UserDefaults
    private let activeWindow: @MainActor () -> NSWindow?
    private let github: GitHubStarCLI
    private let idleTimer = DemandTimer(owner: "GitHubStarPrompt.idle")
    private var shownThisSession = false
    private var observer: (any NSObjectProtocol)?
    private var activity: Any?

    public init(defaults: UserDefaults = .standard, activeWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }) {
        self.defaults = defaults
        self.activeWindow = activeWindow
        github = GitHubStarCLI(repository: Self.repository)
    }

    /// Listens for sent prompts (the app's own run; UpdaterService.start).
    public func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .cmuxPromptSent, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordPromptSent() }
        }
    }

    public func recordPromptSent() {
        guard !shownThisSession, GitHubStarPromptRule.countPrompt(in: defaults) else { return }
        shownThisSession = true
        Task { [weak self, github] in
            let starred = await github.isStarred()
            guard let self else { return }
            // Starred already: the answer is in, never ask.
            if starred == true { return GitHubStarPromptRule.dismiss(in: self.defaults) }
            self.waitForIdle()
        }
    }

    /// Shows after ``idle`` with no key, click or scroll while cmux is frontmost; each input restarts it.
    private func waitForIdle() {
        let restart: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            idleTimer.schedule(after: Self.idle) { @MainActor [weak self] in self?.idleElapsed() }
        }
        activity = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
            MainActor.assumeIsolated { restart() }
            return event
        }
        restart()
    }

    private func idleElapsed() {
        // Input in another app never reaches us: wait for the next one here.
        guard NSApp.isActive else { return }
        if let activity { NSEvent.removeMonitor(activity) }
        activity = nil
        show()
    }

    public func show() {
        guard GitHubStarPromptRule.stillWanted(in: defaults), let window = activeWindow() else { return }
        let toast = CmuxToast(id: "github-star", message: GitHubStarStrings.title, detail: GitHubStarStrings.detail,
                              action: CmuxToast.Action(title: GitHubStarStrings.star),
                              secondaryAction: CmuxToast.Action(title: GitHubStarStrings.dismiss),
                              duration: CmuxToast.untilClosed, placement: .bottomLeading)
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        let defaults = defaults
        handle.onAction = { [weak self] in self?.starInPlace(window: window) }
        handle.onDismiss = { _ in GitHubStarPromptRule.dismiss(in: defaults) }
    }

    private func starInPlace(window: NSWindow) {
        Task { [weak self, github] in
            let starred = await github.star()
            guard self != nil else { return }
            guard starred else { return Self.openInBrowser() }
            let thanks = CmuxToast(id: "github-star-thanks", message: GitHubStarStrings.thanks, detail: GitHubStarStrings.thanksDetail,
                                   duration: .seconds(5), tone: .success, placement: .bottomLeading)
            CmuxToastCenter.shared.show(thanks, in: window)
        }
    }

    static func openInBrowser() {
        guard let url = URL(string: "https://github.com/\(repository)") else { return }
        LinkRouter.shared.open(url, in: .system)
    }
}

/// The person's own GitHub account, through `gh` (the server account t3code uses is the person's here).
nonisolated struct GitHubStarCLI: Sendable {
    let repository: String

    private var gh: URL? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// true starred, false not, nil unknown (no `gh`, not signed in): t3code's unknown asks nothing; here it
    /// asks, since most people have no `gh`, and the button opens the page instead.
    func isStarred() async -> Bool? {
        guard let outcome = await api(["user/starred/\(repository)"]) else { return nil }
        if outcome.exited, outcome.status == 0 { return true }
        let body = String(decoding: outcome.output + outcome.errorOutput, as: UTF8.self)
        return body.contains("404") ? false : nil
    }

    func star() async -> Bool {
        guard let outcome = await api(["-X", "PUT", "user/starred/\(repository)"]) else { return false }
        return outcome.exited && outcome.status == 0
    }

    private func api(_ arguments: [String]) async -> ProcessOutcome? {
        guard let gh else { return nil }
        return try? await AsyncProcess().run(ProcessRequest(gh, ["api"] + arguments, errorOutput: .capture, timeout: .seconds(10)))
    }
}

nonisolated enum GitHubStarStrings {
    static var title: String { String(localized: "githubStar.title", defaultValue: "Enjoying cmux?", table: "GitHubStar", bundle: .localizedModule) }
    static var detail: String {
        String(localized: "githubStar.detail", defaultValue: "Give us a star on GitHub to let us know!", table: "GitHubStar", bundle: .localizedModule)
    }
    static var star: String { String(localized: "githubStar.star", defaultValue: "Star on GitHub", table: "GitHubStar", bundle: .localizedModule) }
    static var dismiss: String { String(localized: "githubStar.dismiss", defaultValue: "Dismiss", table: "GitHubStar", bundle: .localizedModule) }
    static var thanks: String { String(localized: "githubStar.thanks", defaultValue: "Thanks for the star!", table: "GitHubStar", bundle: .localizedModule) }
    static var thanksDetail: String {
        String(localized: "githubStar.thanksDetail", defaultValue: "It really helps cmux grow.", table: "GitHubStar", bundle: .localizedModule)
    }
}
