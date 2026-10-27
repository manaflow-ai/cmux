import CmuxNextWakeups
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
    /// Bench marks (`debug.omnibar_bench`): nil outside a bench run.
    var probe: ((String) -> Void)?

    /// True while the applier writes: field notifications are its echo.
    private(set) var isApplying = false
    private var queue: [OmnibarInput] = []
    private var isRunning = false
    private var queryTask: Task<Void, Never>?
    /// Bumped by every query and cancel: a delivery already posted for an older query does nothing.
    private var queryEpoch: UInt64 = 0
    /// The app's one main-thread scheduler: a query's rows reach the reducer as posted userBlocking tasks.
    private let mainWork: MainWorkScheduler

    init(
        field: any OmnibarFieldSurface,
        popup: any OmnibarPopupSurface,
        resolver: @escaping () -> OmniboxResolver,
        suggest: @escaping (OmniboxRequest) -> AsyncStream<OmniboxDelivery>,
        mainWork: MainWorkScheduler
    ) {
        state = OmnibarState()
        applier = OmnibarEffectApplier(field: field, popup: popup)
        self.resolver = resolver
        self.suggest = suggest
        self.mainWork = mainWork
    }

    #if DEBUG
    /// The newest inputs and the state each left (`debug.omnibar` `pointer.omnibar_trace`):
    /// names the input behind a wrong phase in a live check (cx-d0d.87).
    private(set) var trace: [String] = []
    private func note(_ line: String) {
        trace.append(line)
        if trace.count > 40 { trace.removeFirst() }
    }

    /// Suggestion deliveries as a count, so rows never push the focus and mouse inputs out.
    private static func traceLabel(_ input: OmnibarInput) -> String {
        switch input {
        case .suggestions(let generation, let rows): "suggestions(gen \(generation), \(rows.count) rows)"
        case .moreSuggestions(let generation, let rows, _): "moreSuggestions(gen \(generation), \(rows.count) rows)"
        default: String(describing: input)
        }
    }
    #endif

    /// Reduces `input`. Returns whether it was handled (keys: false lets
    /// the field editor run its default). An input sent while a step runs
    /// is queued and reports false.
    @discardableResult
    func send(_ input: OmnibarInput) -> Bool {
        guard !isRunning else {
            #if DEBUG
            note("queued (applying \(isApplying)): \(Self.traceLabel(input))")
            #endif
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
        probe?("step.begin")
        defer { probe?("step.end") }
        let transition = OmnibarReducer.reduce(state, input, resolver: resolver())
        #if DEBUG
        let next = transition.state
        note("\(Self.traceLabel(input)) -> \(next.phase) elided \(next.elided) \(next.fieldText.debugDescription) \(next.edit.selection)")
        #endif
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
            queryEpoch &+= 1
            let epoch = queryEpoch
            let deliveries = suggest(OmniboxRequest(text: text, generation: generation, gate: gate))
            let mainWork = mainWork
            // The stream is read off main; each delivery is the rest of the person's typing, a userBlocking task
            // that yields to their next key (Chrome posts AutocompleteController's results to the UI thread).
            queryTask = Task { @concurrent [weak self] in
                for await delivery in deliveries {
                    guard !Task.isCancelled else { return }
                    let input: OmnibarInput = switch delivery {
                    case .local(let rows): .suggestions(generation: generation, rows: rows)
                    case .more(let rows, let capacity): .moreSuggestions(generation: generation, rows: rows, capacity: capacity)
                    }
                    await mainWork.apply(.userBlocking, owner: "browser.omnibar.suggestions") { [weak self] () -> Void in
                        self?.deliver(input, epoch: epoch)
                    }
                }
            }
        case .keywordInput(let extensionID, let text, let generation):
            queryTask?.cancel()
            queryEpoch &+= 1
            let suggest = keywordSuggest
            // main-hop-allow: keywordSuggest is the tab's main-actor async chrome.omnibox round trip (the extension answers in Chromium's process); this task only starts it and hands the rows to the reducer
            queryTask = Task { [weak self] in
                let rows = await suggest(extensionID, text)
                guard !Task.isCancelled else { return }
                self?.send(.suggestions(generation: generation, rows: rows))
            }
            onEffect?(effect)
        case .cancelQuery:
            queryTask?.cancel()
            queryTask = nil
            queryEpoch &+= 1
        case .beep, .began, .ended, .deleteSuggestion, .typedNavigation, .typedHTTPSUpgrade, .hostTypoFixed, .copyAnswer, .keywordStarted, .keywordEnded:
            onEffect?(effect)
        }
    }

    /// A delivery of the query still in flight; one posted before a cancel or a newer query does nothing.
    private func deliver(_ input: OmnibarInput, epoch: UInt64) {
        guard epoch == queryEpoch else { return }
        send(input)
    }
}
