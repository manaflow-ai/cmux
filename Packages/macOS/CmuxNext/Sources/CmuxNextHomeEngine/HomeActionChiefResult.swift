public import CmuxNextHomeModel

/// A headless New Chief run's outcome (`home.newChief` from the CLI or MCP): the exact record it made, or why not.
public enum HomeActionChiefResult {
    /// The Chief this run created.
    case success(HomeChiefRecord)
    /// The run made no Chief.
    case failure(HomeComposeOutcome)
}
