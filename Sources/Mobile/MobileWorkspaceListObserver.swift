import Combine
import Foundation
import OSLog

private let mobileWorkspaceObserverLog = Logger(subsystem: "dev.cmux", category: "mobile-workspace-observer")

/// Watches `TabManager.tabs` (and each workspace's panels publisher) and emits
/// `workspace.updated` to subscribed mobile clients whenever the iOS-facing
/// shape of the workspace list materially changes. Replaces per-RPC emit hooks
/// — any mutation surface (UI new-tab, keyboard shortcut, drag-reorder,
/// debug-cli, session restore, etc.) automatically syncs because we observe
/// the `@Published` source of truth instead of trying to catch every caller.
@MainActor
final class MobileWorkspaceListObserver {
    private weak var tabManager: TabManager?
    private var tabsCancellable: AnyCancellable?
    private var perWorkspaceCancellables: [UUID: AnyCancellable] = [:]
    private var lastSummaryHash: Int = 0
    /// Debounce window: coalesce bursts of @Published events (e.g. terminal
    /// rename + selection change firing in the same runloop tick) so we emit
    /// at most ~12 events/sec.
    private let debounceMilliseconds: Int = 80

    init(tabManager: TabManager) {
        self.tabManager = tabManager
        attach(to: tabManager)
    }

    private func attach(to tabManager: TabManager) {
        // Initial snapshot — every observer's first emit is unconditional so
        // freshly-paired clients see the current state without waiting for
        // the first mutation.
        let initial = Self.summaryHash(for: tabManager.tabs)
        lastSummaryHash = initial
        emitIfNeeded(force: true)

        tabsCancellable = tabManager.$tabs
            .debounce(for: .milliseconds(debounceMilliseconds), scheduler: RunLoop.main)
            .sink { [weak self] tabs in
                guard let self else { return }
                self.refreshPerWorkspaceSubscriptions(tabs: tabs)
                self.emitIfNeeded(force: false)
            }

        refreshPerWorkspaceSubscriptions(tabs: tabManager.tabs)
    }

    private func refreshPerWorkspaceSubscriptions(tabs: [Workspace]) {
        let currentIDs = Set(tabs.map(\.id))
        // Drop subscriptions for workspaces that vanished.
        for id in perWorkspaceCancellables.keys where !currentIDs.contains(id) {
            perWorkspaceCancellables.removeValue(forKey: id)
        }
        // Merge the per-workspace publishers we care about (terminal
        // open/close, terminal rename, workspace rename) into one stream so
        // any of them fires a single coalesced emit.
        for workspace in tabs where perWorkspaceCancellables[workspace.id] == nil {
            let panels = workspace.$panels.map { _ in () }
            let titles = workspace.$panelTitles.map { _ in () }
            let title = workspace.$title.map { _ in () }
            let merged = Publishers.Merge3(panels, titles, title)
                .debounce(for: .milliseconds(debounceMilliseconds), scheduler: RunLoop.main)
            perWorkspaceCancellables[workspace.id] = merged.sink { [weak self] _ in
                self?.emitIfNeeded(force: false)
            }
        }
    }

    private func emitIfNeeded(force: Bool) {
        guard let tabManager else { return }
        let hash = Self.summaryHash(for: tabManager.tabs)
        if !force, hash == lastSummaryHash {
            return
        }
        lastSummaryHash = hash
        mobileWorkspaceObserverLog.debug("emitting workspace.updated (hash=\(hash, privacy: .public))")
        MobileHostService.shared.emitEvent(topic: "workspace.updated", payload: [:])
    }

    /// Stable hash of the iOS-facing shape: workspace ids + titles + their
    /// panel id sets + panel titles. Mutations that don't show up on the
    /// mobile list (pane geometry, scrollback content, focus only) don't
    /// trip the event, so we don't fan out on every keystroke.
    private static func summaryHash(for tabs: [Workspace]) -> Int {
        var hasher = Hasher()
        hasher.combine(tabs.count)
        for workspace in tabs {
            hasher.combine(workspace.id)
            hasher.combine(workspace.title)
            // Terminal/panel set + their titles. Sort panel ids so insertion
            // order quirks don't manufacture spurious diffs.
            let panelIDs = workspace.panels.keys.sorted()
            hasher.combine(panelIDs)
            for id in panelIDs {
                hasher.combine(workspace.panelTitles[id])
            }
        }
        return hasher.finalize()
    }
}
