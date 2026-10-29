public import CmuxNextActions

/// The key router's last `KeyContext`, kept while the focus, the app's context bits and the key facts
/// it was built from are equal: a run of chords with no change builds it once.
@MainActor
public final class KeyContextMemo<Focus: Equatable, Facts: Equatable> {
    private var last: (focus: Focus, appContext: ActionContext, facts: Facts, context: KeyContext)?
    /// How many times the context was built.
    public private(set) var builds = 0

    public init() {}

    nonisolated deinit {}

    /// The context for these inputs: the last one when they are equal, else `build`'s (kept).
    public func context(focus: Focus, appContext: ActionContext, facts: Facts, build: () -> KeyContext) -> KeyContext {
        if let last, last.appContext == appContext, last.focus == focus, last.facts == facts { return last.context }
        let context = build()
        builds += 1
        last = (focus, appContext, facts, context)
        return context
    }
}
