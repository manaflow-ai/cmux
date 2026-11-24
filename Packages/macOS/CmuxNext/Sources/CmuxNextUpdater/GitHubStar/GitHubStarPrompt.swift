import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextPages
import CmuxNextWakeups

/// "Enjoying cmux? Give us a star on GitHub to let us know!", bottom-left, until closed. Star on GitHub
/// stars in place through the person's `gh` sign-in and thanks them; without one it opens the repo.
/// Every close (both buttons, the X) saves the dismissal.
@MainActor
public final class GitHubStarPrompt {
    static let repository = "manaflow-ai/cmux"
    static let idle: Duration = .seconds(30)
    static let recheckEvery: Duration = .seconds(600)

    private let defaults: UserDefaults
    private let activeWindow: @MainActor () -> NSWindow?
    private let github: GitHubStarCLI
    private let idleTimer = DemandTimer(owner: "GitHubStarPrompt.idle")
    private let recheck = DemandTimer(owner: "GitHubStarPrompt.recheck")
    private var shownThisSession = false
    private var activity: Any?

    public init(defaults: UserDefaults = .standard, activeWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }) {
        self.defaults = defaults
        self.activeWindow = activeWindow
        github = GitHubStarCLI(repository: Self.repository)
    }

    /// Asks once this session when more than five prompts were sent (counted by the chat pane) and the
    /// person never dismissed it (the app's own run; UpdaterService.start).
    public func start() {
        guard !shownThisSession else { return }
        // Not yet: look again later, since prompts sent this session count too.
        guard GitHubStarPromptCount.wanted(in: defaults) else {
            if !defaults.bool(forKey: GitHubStarPromptCount.dismissedKey) {
                recheck.schedule(after: Self.recheckEvery) { @MainActor [weak self] in self?.start() }
            }
            return
        }
        shownThisSession = true
        Task { [weak self, github] in
            let starred = await github.isStarred()
            guard let self else { return }
            // Starred already: the answer is in, never ask.
            if starred == true { return GitHubStarPromptCount.dismiss(in: self.defaults) }
            self.waitForIdle()
        }
    }

    /// Shows after ``idle`` with no key, click or scroll while cmux is frontmost; each input restarts it.
    private func waitForIdle() {
        let restart: () -> Void = { [weak self] in
            guard let self else { return }
            idleTimer.schedule(after: Self.idle) { @MainActor [weak self] in self?.idleElapsed() }
        }
        activity = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
            restart()
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
        guard !defaults.bool(forKey: GitHubStarPromptCount.dismissedKey), let window = activeWindow() else { return }
        let toast = CmuxToast(id: "github-star", message: GitHubStarStrings.title, detail: GitHubStarStrings.detail,
                              action: CmuxToast.Action(title: GitHubStarStrings.star),
                              secondaryAction: CmuxToast.Action(title: GitHubStarStrings.dismiss),
                              duration: CmuxToast.untilClosed, placement: .bottomLeading)
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        let defaults = defaults
        handle.onAction = { [weak self] in self?.starInPlace(window: window) }
        handle.onDismiss = { _ in GitHubStarPromptCount.dismiss(in: defaults) }
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
            .first { FileManager.checked.isExecutableFile(atPath: $0.path) }
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
