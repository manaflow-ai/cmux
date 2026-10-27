/// Quit and Chromium runtime updates (task 087 of plans/cmux-next/chrome-parity/p01-process.md).
extension CEFEngine {
    /// Before quit closes anything, each page whose beforeunload would ask asks the person; the first Stay ends the
    /// quit (`CEFRuntime.askPagesBeforeQuit`). `showWindows` runs before the first question.
    public func askPagesBeforeQuit(showWindows: () -> Void) async -> ChromiumQuitAnswer {
        await CEFRuntime.shared.askPagesBeforeQuit(showWindows: showWindows) { await $0.asksBeforeQuit(within: CEFRuntime.quitAskLimit) }
    }

    /// Answers every waiting beforeunload question: Leave with `leave`, else Stay.
    public func answerQuitQuestions(leave: Bool) {
        CEFRuntime.shared.answerQuitQuestions(leave: leave)
    }

    /// Where a Chromium runtime update of the host stands (`none`, `waiting: <why>`, `restarting`), with how many
    /// hosts restarted on a newer runtime.
    public var hostRuntimeUpdate: (state: String, restarts: Int) {
        let update = CEFRuntime.shared.hostStart?.runtimeUpdate
        return (update?.report ?? "none", update?.restarts ?? 0)
    }
}

extension ChromiumEngineSlot {
    /// ``CEFEngine/askPagesBeforeQuit(showWindows:)`` when an engine was built; with none no page runs and quit goes on.
    public func askPagesBeforeQuit(showWindows: () -> Void) async -> ChromiumQuitAnswer {
        guard let built else { return .leave(asked: false) }
        return await built.askPagesBeforeQuit(showWindows: showWindows)
    }

    /// ``CEFEngine/answerQuitQuestions(leave:)`` when an engine was built.
    public func answerQuitQuestions(leave: Bool) {
        built?.answerQuitQuestions(leave: leave)
    }
}
