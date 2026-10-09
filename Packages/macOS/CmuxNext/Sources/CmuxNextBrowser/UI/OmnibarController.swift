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
    /// Rows for typed text as they become ready (the suggestion engine).
    var suggest: (OmniboxRequest) -> AsyncStream<OmniboxDelivery>
    /// The newest generation: work for an older one stops delivering.
    let gate = OmniboxGenerationGate()
    /// Rows of an extension keyword session for its text (the tab asks the
    /// extension through `chrome.omnibox`).
    var keywordSuggest: (_ extensionID: String, _ text: String) async -> [BrowserSuggestion] = { _, _ in [] }
    /// `began`, `ended`, `beep` and keyword session boundaries; queries run here.
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
        suggest: @escaping (OmniboxRequest) -> AsyncStream<OmniboxDelivery>
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

    /// The query in flight, if any (tests settle on it): it ends after the
    /// query's last delivery reached the reducer.
    var pendingQuery: Task<Void, Never>? { queryTask }

    @discardableResult
    private func step(_ input: OmnibarInput) -> Bool {
        let transition = OmnibarReducer.reduce(state, input, resolver: resolver())
        state = transition.state
        gate.begin(state.generation)
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
            let deliveries = suggest(OmniboxRequest(text: text, generation: generation, gate: gate))
            queryTask = Task { [weak self] in
                for await delivery in deliveries {
                    guard !Task.isCancelled else { return }
                    switch delivery {
                    case .local(let rows): self?.send(.suggestions(generation: generation, rows: rows))
                    case .more(let rows, let capacity): self?.send(.moreSuggestions(generation: generation, rows: rows, capacity: capacity))
                    }
                }
            }
        case .keywordInput(let extensionID, let text, let generation):
            queryTask?.cancel()
            let suggest = keywordSuggest
            queryTask = Task { [weak self] in
                let rows = await suggest(extensionID, text)
                guard !Task.isCancelled else { return }
                self?.send(.suggestions(generation: generation, rows: rows))
            }
            onEffect?(effect)
        case .cancelQuery:
            queryTask?.cancel()
            queryTask = nil
        case .beep, .began, .ended, .deleteSuggestion, .typedNavigation, .hostTypoFixed, .copyAnswer, .keywordStarted, .keywordEnded:
            onEffect?(effect)
        }
    }
}
