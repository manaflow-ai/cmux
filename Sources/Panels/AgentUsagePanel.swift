import AppKit
import Combine
import CmuxSettings
import Foundation

/// Loads agent usage snapshots off the main actor and publishes the result.
///
/// Uses `ObservableObject` deliberately: the `Panel` protocol this feature
/// plugs into requires it, and every other panel store in the codebase follows
/// the same pattern.
///
/// Local transcript scanning runs on a detached background task. When an
/// OpenRouter API key is configured, its account activity is fetched over the
/// network and merged into the same aggregation, so OpenRouter usage appears in
/// the per-model and per-day breakdowns alongside the local sources.
@MainActor
final class AgentUsageStore: ObservableObject {
    /// The most recent scan result; nil until the first scan completes.
    @Published private(set) var snapshot: AgentUsageSnapshot?
    /// True while a scan is running.
    @Published private(set) var isLoading = false
    /// Human-readable message from the most recent failed OpenRouter fetch, or
    /// nil when OpenRouter is unconfigured or last succeeded.
    @Published private(set) var openRouterError: String?

    /// A snapshot older than this is considered stale by `refreshIfStale()`.
    static let staleInterval: TimeInterval = 5 * 60

    private let scanner: AgentUsageScanner
    private let openRouterClient: OpenRouterUsageClient
    private let openRouterKeyReader: @Sendable () async -> String
    private var refreshTask: Task<Void, Never>?

    /// Creates a store backed by `scanner` (the real home directory by default).
    ///
    /// - Parameters:
    ///   - scanner: Reads local transcripts.
    ///   - openRouterClient: Fetches OpenRouter account usage.
    ///   - openRouterKeyReader: Supplies the OpenRouter API key (empty string
    ///     when none is configured). The default reads the secret file the
    ///     Settings UI writes; tests inject a stub.
    init(
        scanner: AgentUsageScanner = AgentUsageScanner(),
        openRouterClient: OpenRouterUsageClient = OpenRouterUsageClient(),
        openRouterKeyReader: @escaping @Sendable () async -> String = AgentUsageStore.defaultOpenRouterKeyReader()
    ) {
        self.scanner = scanner
        self.openRouterClient = openRouterClient
        self.openRouterKeyReader = openRouterKeyReader
    }

    /// Builds the production OpenRouter key reader: it reads the same `0600`
    /// secret file the Settings UI writes, resolved under the cmux state
    /// directory (matching the app's composition root). File I/O is deferred to
    /// the returned async closure.
    nonisolated static func defaultOpenRouterKeyReader() -> @Sendable () async -> String {
        let baseDirectory = SocketControlPasswordStore.defaultPasswordFileURL(fileManager: .default)?
            .deletingLastPathComponent()
            ?? CmuxStateDirectory.url(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        let store = SecretFileStore(baseDirectory: baseDirectory)
        let key = SettingCatalog().integrations.openRouterApiKey
        return { (try? await store.value(for: key)) ?? "" }
    }

    /// Starts a scan unless one is already running. The file I/O runs on a
    /// background task; results are published back on the main actor.
    func refresh() {
        guard refreshTask == nil else { return }
        isLoading = true
        let scanner = self.scanner
        let client = self.openRouterClient
        let keyReader = self.openRouterKeyReader
        refreshTask = Task { [weak self] in
            let raw = await Task.detached(priority: .utility) {
                scanner.collectLocalUsage()
            }.value

            var events = raw.events
            var credits: OpenRouterCredits?
            var openRouterError: String?
            let apiKey = await keyReader()
            if !apiKey.isEmpty {
                do {
                    let usage = try await client.fetchUsage(apiKey: apiKey)
                    events.append(contentsOf: usage.events)
                    credits = usage.credits
                } catch {
                    openRouterError = error.localizedDescription
                }
            }

            let mergedEvents = events
            let codexRateLimits = raw.codexRateLimits
            let scannedFileCount = raw.scannedFileCount
            var snapshot = await Task.detached(priority: .utility) {
                AgentUsageAggregator.aggregate(
                    events: mergedEvents,
                    codexRateLimits: codexRateLimits,
                    scannedFileCount: scannedFileCount
                )
            }.value
            snapshot.openRouterCredits = credits

            guard let self, !Task.isCancelled else { return }
            self.snapshot = snapshot
            self.openRouterError = openRouterError
            self.isLoading = false
            self.refreshTask = nil
        }
    }

    /// Refreshes when there is no snapshot yet or the current one is older
    /// than `staleInterval`, so a re-shown panel never renders stale data
    /// without kicking off a rescan.
    func refreshIfStale(now: Date = Date()) {
        guard let snapshot else {
            refresh()
            return
        }
        if now.timeIntervalSince(snapshot.generatedAt) > Self.staleInterval {
            refresh()
        }
    }

    /// Cancels any in-flight scan (used when the panel closes).
    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
        isLoading = false
    }
}

/// Panel that shows local Claude Code / Codex token usage, estimated API cost,
/// and plan-limit windows.
@MainActor
final class AgentUsagePanel: Panel, ObservableObject {
    /// Unique panel identity.
    let id: UUID
    /// Always `.agentUsage`.
    let panelType: PanelType = .agentUsage
    /// Backing store that scans transcripts and publishes snapshots.
    let usageStore: AgentUsageStore

    /// Incremented to drive the attention flash ring animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// Creates a panel with a fresh store.
    init() {
        self.id = UUID()
        self.usageStore = AgentUsageStore()
    }

    /// Localized tab title.
    var displayTitle: String {
        String(localized: "panel.agentUsage.title", defaultValue: "Agent Usage")
    }

    /// SF Symbol shown in the tab.
    var displayIcon: String? { "chart.bar.xaxis" }

    /// Cancels any in-flight scan; the panel holds no other resources.
    func close() {
        usageStore.cancel()
    }

    /// The panel has no focusable text input; focus is a no-op.
    func focus() {}

    /// Counterpart to `focus()`; also a no-op.
    func unfocus() {}

    /// Triggers the attention flash ring when pane flashes are enabled.
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }
}
