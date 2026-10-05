public import Foundation

/// One query of one omnibar: its text, its generation, and the gate that
/// says whether the generation is still the newest.
public nonisolated struct OmniboxRequest: Sendable {
    public var text: String
    public var generation: UInt64
    public var gate: OmniboxGenerationGate
    /// The tab that asks (never offered as its own Switch to Tab row).
    public var tabKey: String?

    public init(text: String, generation: UInt64, gate: OmniboxGenerationGate, tabKey: String? = nil) {
        self.text = text
        self.generation = generation
        self.gate = gate
        self.tabKey = tabKey
    }
}

/// Rows of one query as they become ready.
public nonisolated enum OmniboxDelivery: Equatable, Sendable {
    /// Phase A: what-you-typed and the local rows. Replaces the rows.
    case local([BrowserSuggestion])

    /// A stream that ends with no rows.
    public static var finished: AsyncStream<OmniboxDelivery> {
        let (stream, continuation) = AsyncStream.makeStream(of: OmniboxDelivery.self, bufferingPolicy: .bufferingNewest(1))
        continuation.finish()
        return stream
    }
}

/// Builds the dropdown for every omnibar of one browser profile
/// (plans/cmux-next/omnibar-suggestions.md). Phase A runs on `local`, an
/// actor that owns the quick history index fed by `history`, bookmarks and
/// open tabs; `providers` are other local row sources of the App, merged
/// into the phase A rows.
public final class OmniboxSuggestionEngine {
    public var resolver: OmniboxResolver
    public var providers: [any BrowserSuggestionProvider]
    public var maxResults: Int
    /// Enabled sources in tie-break order (`browser.omnibar.sources`).
    public var sources: [OmniboxSource] = OmniboxSource.defaultOrder
    /// `browser.omnibar.inlineAutocomplete`.
    public var inlineAutocomplete = true
    /// Open tabs of the profile, read on every query (Switch to Tab rows).
    public var openTabs: () -> [OmniboxTabRow] = { [] }
    /// Reveals the tab of a chosen Switch to Tab row (the App's tab search path).
    public var revealTab: (String) -> Void = { _ in }
    public let local: OmniboxLocalIndex
    public private(set) var history: (any OmniboxHistorySource)?
    var now: () -> Date = Date.init
    private var historyToken: Int?
    /// History changes not yet applied to `local`, oldest first.
    private var pendingChanges: [OmniboxHistoryChange] = []
    private var awaitingSnapshot = false
    private var pumpTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var bookmarkTask: Task<Void, Never>?

    public init(resolver: OmniboxResolver = OmniboxResolver(), providers: [any BrowserSuggestionProvider] = [], maxResults: Int = 8,
                history: (any OmniboxHistorySource)? = nil) {
        self.resolver = resolver
        self.providers = providers
        self.maxResults = maxResults
        local = OmniboxLocalIndex()
        if let history { attach(history) }
    }

    /// Follows `source` from now on: its changes queue at once, its snapshot
    /// goes first, and one apply at a time keeps them in order.
    public func attach(_ source: any OmniboxHistorySource) {
        if let historyToken { history?.stopObserving(historyToken) }
        history = source
        awaitingSnapshot = true
        pendingChanges = []
        historyToken = source.observe { [weak self] change in self?.enqueue(change) }
        snapshotTask = Task { [weak self, weak source] in
            guard let rows = await source?.snapshot(), let self else { return }
            pendingChanges.insert(.reset(rows), at: 0)
            awaitingSnapshot = false
            pump()
        }
    }

    /// Every bookmark of the profile (the App's bookmark feed). Each set
    /// waits for the one before it, so the newest wins.
    public func setBookmarks(_ rows: [OmniboxHistoryRow]) {
        let local = self.local, now = self.now(), previous = bookmarkTask
        bookmarkTask = Task {
            await previous?.value
            await local.setBookmarks(rows, now: now)
        }
    }

    /// Rows of `request` as they become ready. Cancelling the iteration
    /// (the controller's next query) cancels the work.
    public func deliveries(for request: OmniboxRequest) -> AsyncStream<OmniboxDelivery> {
        let (stream, continuation) = AsyncStream.makeStream(of: OmniboxDelivery.self, bufferingPolicy: .bufferingNewest(8))
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = OmniboxLocalQuery(
            generation: request.generation, gate: request.gate, text: text, resolver: resolver, maxRows: maxResults,
            sources: sources, inlineAutocomplete: inlineAutocomplete,
            tabs: sources.contains(.tabs) ? openTabs().filter { $0.key != request.tabKey } : [], now: now()
        )
        let local = self.local, providers = self.providers, maxRows = maxResults
        let task = Task {
            guard var rows = await local.run(query) else { return continuation.finish() }
            if !providers.isEmpty, !text.isEmpty {
                var extra: [BrowserSuggestion] = []
                for provider in providers {
                    if Task.isCancelled { return continuation.finish() }
                    extra += await provider.suggestions(for: text)
                }
                rows = OmniboxPhaseA.merging(rows, extra, maxRows: maxRows)
            }
            if !Task.isCancelled, request.gate.isCurrent(request.generation) { continuation.yield(.local(rows)) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Every row of one query once all phases finished (tests, one-shot callers).
    public func suggestions(for text: String) async -> [BrowserSuggestion] {
        let gate = OmniboxGenerationGate()
        gate.begin(1)
        var rows: [BrowserSuggestion] = []
        for await delivery in deliveries(for: OmniboxRequest(text: text, generation: 1, gate: gate)) {
            switch delivery {
            case .local(let local): rows = local
            }
        }
        return rows
    }

    /// Shift-Delete on a history row: the history source forgets `url`, and
    /// every provider that can forget it does (Chromium `AutocompleteController::DeleteMatch`).
    public func deleteSuggestion(_ url: URL) {
        history?.delete(url)
        for case let provider as any BrowserSuggestionDeleting in providers {
            provider.deleteSuggestion(url)
        }
    }

    /// Enter loaded typed text as `url`.
    public func noteTyped(_ url: URL) {
        history?.noteTyped(url)
    }

    /// The row Enter picks when nothing is selected.
    public func primarySuggestion(for text: String) -> BrowserSuggestion? {
        OmniboxPhaseA.primary(for: text, resolver: resolver)
    }

    /// Resolves once every history change and bookmark set received so far
    /// is in the index (tests).
    public func historySettled() async {
        await snapshotTask?.value
        while let task = pumpTask { await task.value }
        await bookmarkTask?.value
    }

    // MARK: History pump

    private func enqueue(_ change: OmniboxHistoryChange) {
        pendingChanges.append(change)
        pump()
    }

    private func pump() {
        guard pumpTask == nil, !awaitingSnapshot, !pendingChanges.isEmpty else { return }
        let batch = pendingChanges
        pendingChanges = []
        let local = self.local, now = self.now()
        pumpTask = Task { [weak self] in
            await local.apply(batch, now: now)
            self?.pumpTask = nil
            self?.pump()
        }
    }
}
