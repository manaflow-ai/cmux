public import Foundation

/// The one-time GitHub star ask in the tip card's slot (``StarPromptCenter``): what its card's presses do.
extension UpdaterService {
    /// The star card's notice id.
    public static let starCardID = "star"
    /// The star card's one button (Open GitHub).
    public static let starOpenAction = "open-github"

    /// A press on the star card: its button (``starOpenAction``) opens the repository and ends the ask; being on
    /// screen (``tipShownAction``) spends it from the next launch on.
    public func starCardAction(_ action: String) {
        switch action {
        case Self.starOpenAction: starPromptFinished(starred: true)
        case Self.tipShownAction: starPromptShown()
        default: break
        }
    }

    /// The card is on screen: the ask is spent from the next launch on, and it spends the tips' budget, so no
    /// tip follows it for `FeatureTipBudget.minimumDaysBetweenTips` days.
    public func starPromptShown() {
        if starPrompt.markShown() { tipBudget.spend(at: now()) }
    }

    /// The card's x or its button: it never shows again, and no tip takes the slot this launch.
    public func starPromptFinished(starred: Bool) {
        if starred { starPrompt.starred() } else { starPrompt.dismiss() }
        if tip != nil { tip = nil }
    }

    /// `debug.updater {action: "star", press?}` (DEV and NIGHTLY): with no `press` shows the card now;
    /// `press: "reset"` forgets everything it remembers (a fresh install); `press: "x"` or `"open"` presses it.
    /// Returns what it remembers.
    public func debugStarPrompt(press: String?) -> [String: String] {
        switch press {
        case "reset": starPrompt.debugReset()
        case "x": starPromptFinished(starred: false)
        case "open": starPromptFinished(starred: true)
        default:
            if tip != nil { tip = nil }
            starPrompt.debugShow()
        }
        let record = starPrompt.snapshot
        var state = ["offered": String(starPrompt.isOffered), "done": String(record.done), "launches": String(record.launches)]
        state["firstLaunchAt"] = record.firstLaunchAt.map { ISO8601DateFormatter().string(from: $0) }
        state["shownInLaunch"] = record.shownInLaunch.map(String.init)
        return state
    }
}
