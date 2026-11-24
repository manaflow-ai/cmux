import AppKit
import CmuxNextDesign
import CmuxNextPages
import CmuxNextWakeups

/// When to ask for a GitHub star (the same rule as t3code's GitHubStarPrompt): count each launch, and
/// from the sixth on ask once per launch until the person stars or dismisses; any close is for good.
/// Storage that cannot keep a dismissal never asks.
public nonisolated struct GitHubStarPromptRule: Sendable {
    public nonisolated init() {}
    static let launchesBeforeAsking = 5
    static let launchesKey = "cmux.githubStar.launches"
    static let dismissedKey = "cmux.githubStar.dismissed"

    /// Counts this launch and says whether to ask in it.
    public static func countLaunch(in defaults: UserDefaults) -> Bool {
        if defaults.bool(forKey: dismissedKey) { return false }
        let launches = defaults.integer(forKey: launchesKey) + 1
        defaults.set(launches, forKey: launchesKey)
        return launches > launchesBeforeAsking
    }

    /// Whether to ask now: another window or launch may have dismissed it meanwhile.
    public static func stillWanted(in defaults: UserDefaults) -> Bool { !defaults.bool(forKey: dismissedKey) }

    public static func dismiss(in defaults: UserDefaults) { defaults.set(true, forKey: dismissedKey) }
}

/// "Enjoying cmux? Give us a star on GitHub", bottom-leading, until closed. Star on GitHub opens the repo
/// in the browser; Star and Not Now both end the ask for good.
@MainActor
public final class GitHubStarPrompt {
    static let repository: URL? = URL(string: "https://github.com/manaflow-ai/cmux")
    /// How long after launch it waits, so it never lands on the person's first seconds of work.
    static let delay: Duration = .seconds(120)

    private let defaults: UserDefaults
    private let activeWindow: @MainActor () -> NSWindow?
    private let timer = DemandTimer(owner: "GitHubStarPrompt.delay")
    private var started = false
    private var handle: CmuxToastHandle?

    public init(defaults: UserDefaults = .standard, activeWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }) {
        self.defaults = defaults
        self.activeWindow = activeWindow
    }

    public func start() {
        guard !started else { return }
        started = true
        guard GitHubStarPromptRule.countLaunch(in: defaults) else { return }
        timer.schedule(after: Self.delay) { @MainActor [weak self] in self?.show() }
    }

    public func show() {
        guard handle == nil, GitHubStarPromptRule.stillWanted(in: defaults), let window = activeWindow() else { return }
        let toast = CmuxToast(id: "github-star", message: GitHubStarStrings.message, detail: GitHubStarStrings.detail,
                              action: CmuxToast.Action(title: GitHubStarStrings.star),
                              secondaryAction: CmuxToast.Action(title: GitHubStarStrings.notNow),
                              duration: CmuxToast.untilClosed, placement: .bottomLeading)
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        self.handle = handle
        let defaults = defaults
        handle.onAction = { if let url = Self.repository { LinkRouter.shared.open(url, in: .system) } }
        // Every way it ends (Star, Not Now, the close button) is the answer: it never asks again.
        handle.onDismiss = { [weak self] _ in
            GitHubStarPromptRule.dismiss(in: defaults)
            self?.handle = nil
        }
    }
}

nonisolated enum GitHubStarStrings {
    static var message: String {
        String(localized: "githubStar.message", defaultValue: "Enjoying cmux?", table: "GitHubStar", bundle: .localizedModule)
    }
    static var detail: String {
        String(localized: "githubStar.detail", defaultValue: "Give us a star on GitHub to let us know!", table: "GitHubStar",
               bundle: .localizedModule)
    }
    static var star: String {
        String(localized: "githubStar.star", defaultValue: "Star on GitHub", table: "GitHubStar", bundle: .localizedModule)
    }
    static var notNow: String {
        String(localized: "githubStar.notNow", defaultValue: "Not Now", table: "GitHubStar", bundle: .localizedModule)
    }
}
