import Foundation

/// Runs the omnibar state machine: reduces inputs in FIFO order, applies
/// the presentation, then runs effects. Inputs raised while a step runs
/// (a focus change caused by a commit) queue behind it, so the reducer is
/// never re-entered.
@MainActor final class OmnibarController {
    private(set) var state: OmnibarState
    let applier: OmnibarEffectApplier
    /// The resolver the reducer uses for Enter and Paste and Go.
    var resolver: () -> OmniboxResolver
    /// Rows for typed text (the suggestion engine).
    var suggest: (String) async -> [BrowserSuggestion]
    /// `began`, `ended` and `beep`; queries run here.
    var onEffect: ((OmnibarEffect) -> Void)?
    /// After every step (bar and chip appearance).
    var onStep: (() -> Void)?

    /// True while the applier writes: field notifications are its echo.
    private(set) var isApplying = false
    private var queue: [OmnibarInput] = []
    private var isRunning = false
    private var queryTask: Task<Void, Never>?

    init(
        field: any OmnibarFieldSurface,
        popup: any OmnibarPopupSurface,
        resolver: @escaping () -> OmniboxResolver,
        suggest: @escaping (String) async -> [BrowserSuggestion]
    ) {
        state = OmnibarState()
        applier = OmnibarEffectApplier(field: field, popup: popup)
        self.resolver = resolver
        self.suggest = suggest
    }

    /// Reduces `input`. Returns whether it was handled (keys: false lets
    /// the field editor run its default). An input sent while a step runs
    /// is queued and reports false.
    @discardableResult
    func send(_ input: OmnibarInput) -> Bool {
        guard !isRunning else {
            queue.append(input)
            return false
        }
        isRunning = true
        defer { isRunning = false }
        let handled = step(input)
        while !queue.isEmpty { step(queue.removeFirst()) }
        return handled
    }

    /// The query in flight, if any (tests settle on it).
    var pendingQuery: Task<Void, Never>? { queryTask }

    @discardableResult
    private func step(_ input: OmnibarInput) -> Bool {
        let transition = OmnibarReducer.reduce(state, input, resolver: resolver())
        state = transition.state
        isApplying = true
        applier.apply(OmnibarPresentation(state))
        isApplying = false
        for effect in transition.effects { run(effect) }
        onStep?()
        return transition.handled
    }

    private func run(_ effect: OmnibarEffect) {
        switch effect {
        case .query(let generation, let text):
            queryTask?.cancel()
            let suggest = suggest
            queryTask = Task { [weak self] in
                let rows = await suggest(text)
                guard !Task.isCancelled else { return }
                self?.send(.suggestions(generation: generation, rows: rows))
            }
        case .cancelQuery:
            queryTask?.cancel()
            queryTask = nil
        case .beep, .began, .ended:
            onEffect?(effect)
        }
    }
}
