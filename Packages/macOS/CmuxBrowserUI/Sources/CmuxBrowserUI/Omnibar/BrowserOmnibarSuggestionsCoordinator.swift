public import CmuxBrowser
public import CmuxSettings
public import Foundation
#if DEBUG
import CMUXDebugLog
#endif

/// Read/write seam the omnibar-suggestions coordinator uses to reach the live
/// address-bar view state that stays app-side.
///
/// The coordinator owns the suggestion data, scheduling, and fetch lifecycle,
/// but the omnibar's edit buffer, focus, marked-text, and selection live on the
/// SwiftUI panel view as `@State`, and the reducer plus focus-handoff effects
/// stay app-side. The view conforms to this protocol so the coordinator can read
/// that live state (reference-backed `@State` reads stay live even through the
/// boxed existential a long-lived refresh task captures) and push resolved
/// suggestions / inline completions back through the app-side reducer.
@MainActor
public protocol BrowserOmnibarSuggestionsHost {
    /// Whether the address bar currently holds keyboard focus.
    var omnibarAddressBarFocused: Bool { get }
    /// Whether the field editor has uncommitted marked (IME composition) text.
    var omnibarHasMarkedText: Bool { get }
    /// The current omnibar edit buffer (`omnibarState.buffer`).
    var omnibarBuffer: String { get }
    /// The current resolved suggestion list (`omnibarState.suggestions`).
    var omnibarSuggestions: [OmnibarSuggestion] { get }
    /// The field editor's current selection range.
    var omnibarSelectionRange: NSRange { get }
    /// The resolved search configuration (engine + display name).
    var omnibarSearchConfiguration: BrowserSearchConfiguration { get }
    /// Whether remote (network) suggestions are allowed this session.
    var omnibarRemoteSuggestionsEnabled: Bool { get }
    /// The owning panel's id, used for DEBUG suggestion logging.
    var omnibarPanelID: UUID { get }
    /// The omnibar pill frame width, used for DEBUG suggestion logging.
    var omnibarPillFrameWidth: CGFloat { get }
    /// Whether suggestions render in the AppKit portal, for DEBUG logging.
    var omnibarShouldRenderSuggestionsInPortal: Bool { get }

    /// Apply a freshly built suggestion list through the app-side reducer
    /// (`applyOmnibarEffects(omnibarState.reduce(.suggestionsUpdated(items)))`).
    func applyOmnibarSuggestions(_ items: [OmnibarSuggestion])
    /// Store the recomputed inline completion (or clear it) on the view.
    func setOmnibarInlineCompletion(_ completion: OmnibarInlineCompletion?)
}

/// Owns the omnibar suggestion sub-domain: debounce scheduling, the remote
/// fetch lifecycle, the stale/forced remote bookkeeping, and the pure ranking
/// engine, all behind app-injected closures that reach the panel history store,
/// open-tab index (via `AppDelegate`/`TabManager`), and navigable-URL resolver.
///
/// The owning ``BrowserOmnibarSuggestionsHost`` (the panel view) holds this via
/// `@State` and forwards `refreshSuggestions()` / `refreshInlineCompletion()` /
/// consumer lifecycle calls so every existing call site resolves unchanged. The
/// `AppDelegate` dependency stays app-side, captured in the injected closures.
@MainActor
@Observable
public final class BrowserOmnibarSuggestionsCoordinator {
    @ObservationIgnored private let historySuggestions: @MainActor (String, Int) -> [BrowserHistoryEntry]
    @ObservationIgnored private let recentHistorySuggestions: @MainActor (Int) -> [BrowserHistoryEntry]
    @ObservationIgnored private let matchingOpenTabs: @MainActor (String, Int) -> [OmnibarOpenTabMatch]
    @ObservationIgnored private let resolveNavigableURL: @MainActor (String) -> URL?
    @ObservationIgnored private let searchSuggestionService = BrowserSearchSuggestionService()

    @ObservationIgnored private let omnibarSuggestionRefreshScheduler = OmnibarSuggestionRefreshScheduler()
    @ObservationIgnored private var omnibarSuggestionRefreshConsumerTask: Task<Void, Never>?
    @ObservationIgnored private var suggestionTask: Task<Void, Never>?
    private var isLoadingRemoteSuggestions: Bool = false
    @ObservationIgnored private var latestRemoteSuggestionQuery: String = ""
    @ObservationIgnored private var latestRemoteSuggestions: [String] = []

    /// Creates the coordinator with closures bound to the app-side panel and
    /// `AppDelegate`/`TabManager` (kept out of this package).
    ///
    /// - Parameters:
    ///   - historySuggestions: history rows matching a query, with a row limit.
    ///   - recentHistorySuggestions: most-recent history rows for an empty query.
    ///   - matchingOpenTabs: open-tab matches for a query (reaches `TabManager`).
    ///   - resolveNavigableURL: the panel's address-bar URL resolver.
    public init(
        historySuggestions: @escaping @MainActor (String, Int) -> [BrowserHistoryEntry],
        recentHistorySuggestions: @escaping @MainActor (Int) -> [BrowserHistoryEntry],
        matchingOpenTabs: @escaping @MainActor (String, Int) -> [OmnibarOpenTabMatch],
        resolveNavigableURL: @escaping @MainActor (String) -> URL?
    ) {
        self.historySuggestions = historySuggestions
        self.recentHistorySuggestions = recentHistorySuggestions
        self.matchingOpenTabs = matchingOpenTabs
        self.resolveNavigableURL = resolveNavigableURL
    }

    /// Whether a remote suggestion fetch is currently in flight (observable so
    /// the suggestions overlay can show its loading spinner).
    public var isLoadingRemoteSuggestionsForDisplay: Bool { isLoadingRemoteSuggestions }

    /// Debounce the next suggestion refresh (called from the app-side effects).
    public func scheduleRefresh() {
        omnibarSuggestionRefreshScheduler.scheduleRefresh()
    }

    /// Start draining the debounced refresh stream, running a refresh against
    /// `host` for the newest generation only.
    public func startRefreshConsumer(host: any BrowserOmnibarSuggestionsHost) {
        guard omnibarSuggestionRefreshConsumerTask == nil else { return }
        let scheduler = omnibarSuggestionRefreshScheduler
        omnibarSuggestionRefreshConsumerTask = Task { @MainActor [weak self] in
            for await generation in scheduler.refreshStream {
                guard scheduler.shouldProcessRefresh(generation) else { continue }
                self?.refreshSuggestions(host: host)
            }
        }
    }

    /// Stop draining the debounced refresh stream.
    public func stopRefreshConsumer() {
        omnibarSuggestionRefreshConsumerTask?.cancel()
        omnibarSuggestionRefreshConsumerTask = nil
    }

    /// Cancel any queued debounce and any in-flight remote fetch.
    public func cancelPendingWork() {
        omnibarSuggestionRefreshScheduler.cancelPendingRefresh()
        suggestionTask?.cancel()
        suggestionTask = nil
        isLoadingRemoteSuggestions = false
    }

    /// Recompute the inline completion from the host's live omnibar state.
    public func refreshInlineCompletion(host: any BrowserOmnibarSuggestionsHost) {
        host.setOmnibarInlineCompletion(
            OmnibarInlineCompletion.forDisplay(
                typedText: host.omnibarBuffer,
                suggestions: host.omnibarSuggestions,
                isFocused: host.omnibarAddressBarFocused,
                selectionRange: host.omnibarSelectionRange,
                hasMarkedText: host.omnibarHasMarkedText
            )
        )
    }

    /// Rebuild the omnibar suggestion list for the host's current query: local
    /// (history + open-tab + stale-remote) rows synchronously, then a debounced
    /// remote fetch that merges fresh predictions when allowed.
    public func refreshSuggestions(host: any BrowserOmnibarSuggestionsHost) {
        suggestionTask?.cancel()
        suggestionTask = nil
        isLoadingRemoteSuggestions = false

        guard host.omnibarAddressBarFocused, !host.omnibarHasMarkedText else {
#if DEBUG
            logDebugEvent(
                "browser.omnibar.suggestions refresh=skip " +
                "panel=\(host.omnibarPanelID.uuidString.prefix(5)) " +
                "focused=\(host.omnibarAddressBarFocused ? 1 : 0) marked=\(host.omnibarHasMarkedText ? 1 : 0) " +
                "bufferLen=\(host.omnibarBuffer.utf8.count)"
            )
#endif
            host.applyOmnibarSuggestions([])
            return
        }

        let query = host.omnibarBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchConfiguration = host.omnibarSearchConfiguration
        let remoteSuggestionsEnabled = host.omnibarRemoteSuggestionsEnabled
        let historyEntries: [BrowserHistoryEntry] = {
            if query.isEmpty {
                return recentHistorySuggestions(12)
            }
            return historySuggestions(query, 12)
        }()
        let openTabMatches = query.isEmpty ? [] : matchingOpenTabs(query, 12)
        let isSingleCharacterQuery = query.omnibarSingleCharacterQuery != nil
        let remoteSuggestionsEngine = searchConfiguration.remoteSuggestionsEngine
        let allowsRemoteSuggestions = remoteSuggestionsEnabled && remoteSuggestionsEngine != nil
        if !allowsRemoteSuggestions {
            latestRemoteSuggestionQuery = ""
            latestRemoteSuggestions = []
        }
        let staleRemote: [String]
        if query.isEmpty || isSingleCharacterQuery {
            staleRemote = []
        } else {
            staleRemote = staleRemoteSuggestionsForDisplay(
                query: query,
                allowsRemoteSuggestions: allowsRemoteSuggestions
            )
        }
        let resolvedURL = query.isEmpty ? nil : resolveNavigableURL(query)
        let items = omnibarSuggestionEngine.buildSuggestions(
            query: query,
            engineName: searchConfiguration.displayName,
            historyEntries: historyEntries,
            openTabMatches: openTabMatches,
            remoteQueries: staleRemote,
            resolvedURL: resolvedURL,
            limit: 8
        )
        host.applyOmnibarSuggestions(items)
        refreshInlineCompletion(host: host)
#if DEBUG
        logDebugEvent(
            "browser.omnibar.suggestions refresh=local " +
            "panel=\(host.omnibarPanelID.uuidString.prefix(5)) queryLen=\(query.utf8.count) " +
            "items=\(items.count) history=\(historyEntries.count) openTabs=\(openTabMatches.count) " +
            "staleRemote=\(staleRemote.count) frameWidth=\(String(format: "%.1f", host.omnibarPillFrameWidth)) " +
            "portal=\(host.omnibarShouldRenderSuggestionsInPortal ? 1 : 0)"
        )
#endif

        guard !query.isEmpty else { return }

        if !isSingleCharacterQuery, let forcedRemote = forcedRemoteSuggestionsForUITest() {
            latestRemoteSuggestionQuery = query
            latestRemoteSuggestions = forcedRemote
            let merged = omnibarSuggestionEngine.buildSuggestions(
                query: query,
                engineName: searchConfiguration.displayName,
                historyEntries: historyEntries,
                openTabMatches: openTabMatches,
                remoteQueries: forcedRemote,
                resolvedURL: resolvedURL,
                limit: 8
            )
            host.applyOmnibarSuggestions(merged)
            refreshInlineCompletion(host: host)
#if DEBUG
            logDebugEvent(
                "browser.omnibar.suggestions refresh=forcedRemote " +
                "panel=\(host.omnibarPanelID.uuidString.prefix(5)) queryLen=\(query.utf8.count) items=\(merged.count)"
            )
#endif
            return
        }

        guard remoteSuggestionsEnabled else { return }
        guard !isSingleCharacterQuery else { return }
        guard omnibarSuggestionEngine.inputIntent(for: query) != .urlLike else { return }

        // Keep current remote rows visible while fetching fresh predictions.
        guard let engine = remoteSuggestionsEngine else { return }
        let service = searchSuggestionService
        isLoadingRemoteSuggestions = true
        suggestionTask = Task { @MainActor [weak self] in
            let remote = await service.suggestions(engine: engine, query: query)
            if Task.isCancelled { return }
            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard host.omnibarAddressBarFocused, !host.omnibarHasMarkedText else { return }
            let current = host.omnibarBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard current == query else { return }
            self.latestRemoteSuggestionQuery = query
            self.latestRemoteSuggestions = remote
            let merged = self.omnibarSuggestionEngine.buildSuggestions(
                query: query,
                engineName: host.omnibarSearchConfiguration.displayName,
                historyEntries: self.historySuggestions(query, 12),
                openTabMatches: self.matchingOpenTabs(query, 12),
                remoteQueries: remote,
                resolvedURL: self.resolveNavigableURL(query),
                limit: 8
            )
            host.applyOmnibarSuggestions(merged)
            self.refreshInlineCompletion(host: host)
            self.isLoadingRemoteSuggestions = false
#if DEBUG
            logDebugEvent(
                "browser.omnibar.suggestions refresh=remote " +
                "panel=\(host.omnibarPanelID.uuidString.prefix(5)) queryLen=\(query.utf8.count) " +
                "remote=\(remote.count) items=\(merged.count)"
            )
#endif
        }
    }

    /// The pure omnibar ranking engine, wired to the app's navigable-URL
    /// resolver so URL-intent classification matches address-bar navigation.
    private var omnibarSuggestionEngine: BrowserOmnibarSuggestionEngine {
        BrowserOmnibarSuggestionEngine(resolveNavigableURL: { $0.omnibarNavigableURL })
    }

    private func staleRemoteSuggestionsForDisplay(
        query: String,
        allowsRemoteSuggestions: Bool = true
    ) -> [String] {
        omnibarSuggestionEngine.staleRemoteSuggestionsForDisplay(
            query: query,
            previousRemoteQuery: latestRemoteSuggestionQuery,
            previousRemoteSuggestions: latestRemoteSuggestions,
            allowsRemoteSuggestions: allowsRemoteSuggestions
        )
    }

    private func forcedRemoteSuggestionsForUITest() -> [String]? {
        let raw = ProcessInfo.processInfo.environment["CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON"]
            ?? UserDefaults.standard.string(forKey: "CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON")
        guard let raw,
              let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }

        let values = parsed.compactMap { item -> String? in
            guard let s = item as? String else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return values.isEmpty ? nil : values
    }
}
