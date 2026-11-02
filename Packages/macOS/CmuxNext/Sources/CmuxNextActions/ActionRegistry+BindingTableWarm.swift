public import CmuxNextWakeups

extension ActionRegistry {
    /// A registry seeded with the full cmux catalog whose stale key-binding table is rebuilt in a budgeted
    /// background batch on `mainWork` (it yields to a person's input), never on the turn of the key that needs it
    /// (TYPING UNDER LOAD F3: the first Left arrow after a change paid `makeTable()`, 27.6 ms on the main thread).
    ///
    /// - Parameters:
    ///   - runTiming: Times every run (the App passes ``SignpostActionRunTiming``).
    ///   - mainWork: The app's main-thread scheduler; the warm batch is one ``FrameBatchQueue`` on it.
    public static func standard(runTiming: any ActionRunTiming, warmingOn mainWork: MainWorkScheduler) -> ActionRegistry {
        let registry = standard(runTiming: runTiming)
        let warm = FrameBatchQueue(owner: "KeyBindings.warm", budgeted: .background, on: mainWork)
        registry.warmBindingTable = { warm.enqueue($0) }
        return registry
    }
}
