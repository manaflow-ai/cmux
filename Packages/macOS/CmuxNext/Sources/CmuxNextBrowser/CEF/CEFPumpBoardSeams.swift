public import CmuxNextWakeups
public import Foundation

/// What the in-process pump's board (``CEFPumpBoard``) reads from the app: the main-thread budget its
/// passes run on as owner `cef.pump`, and the frame clock's refresh interval, how long a page's input
/// keeps the passes in the input class. `CEFEngine.init` takes it; nil: the passes are not on the board.
///
/// ```swift
/// CEFEngine(source: source, stores: stores, signInCallbacks: callbacks, input: inputTap,
///           pumpBoard: CEFPumpBoardSeams(mainWork: mainWork))
/// ```
public struct CEFPumpBoardSeams {
    /// The app's main-thread budget.
    public let budget: MainFrameBudget
    /// The frame clock's refresh interval in seconds.
    public let refreshInterval: @MainActor () -> TimeInterval

    public init(budget: MainFrameBudget, refreshInterval: @escaping @MainActor () -> TimeInterval) {
        self.budget = budget
        self.refreshInterval = refreshInterval
    }

    /// The app's: the main-thread budget and its frame scheduler's refresh period.
    public init(mainWork: MainWorkScheduler) {
        let frames = mainWork.frames
        self.init(budget: mainWork.budget, refreshInterval: { [weak frames] in frames?.refreshPeriod ?? 1.0 / 60 })
    }
}
