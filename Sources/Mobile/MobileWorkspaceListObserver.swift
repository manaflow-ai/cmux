import Combine
import Foundation
import OSLog

private let mobileWorkspaceObserverLog = Logger(subsystem: "dev.cmux", category: "mobile-workspace-observer")

/// Watches `TabManager.tabs` (and each workspace's panels publisher) and emits
/// `workspace.updated` to subscribed mobile clients whenever the iOS-facing
/// shape of the workspace list materially changes. Replaces per-RPC emit hooks
/// Any mutation surface (UI new-tab, keyboard shortcut, drag-reorder,
/// debug-cli, session restore, etc.) automatically syncs because we observe
/// the `@Published` source of truth instead of trying to catch every caller.
@MainActor
final class MobileWorkspaceListObserver {
    private weak var tabManager: TabManager?
    private var tabsCancellable: AnyCancellable?
    private var selectionCancellable: AnyCancellable?
    private var perWorkspaceCancellables: [UUID: AnyCancellable] = [:]
    private var lastSummaryHash: Int = 0
    /// Throttle window with `latest: true`. First event in a burst emits
    /// immediately (iPhone gets the change in milliseconds), subsequent
    /// events within the window collapse to one trailing emit carrying the
    /// final state. So a single action is instant; a burst caps at ~1 emit
    /// per 80 ms. Hash-diff suppresses no-op rebroadcasts.
    private let throttleMilliseconds: Int = 80

    init(tabManager: TabManager) {
        self.tabManager = tabManager
        #if DEBUG
        cmuxDebugLog("mobile.observer init tabs=\(tabManager.tabs.count)")
        #endif
        attach(to: tabManager)
    }

    private func attach(to tabManager: TabManager) {
        // Initial snapshot. Every observer's first emit is unconditional so
        // freshly-paired clients see the current state without waiting for
        // the first mutation.
        let initial = Self.summaryHash(for: tabManager.tabs, selectedTabID: tabManager.selectedTabId)
        lastSummaryHash = initial
        emitIfNeeded(force: true)

        tabsCancellable = tabManager.$tabs
            .throttle(for: .milliseconds(throttleMilliseconds), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] tabs in
                guard let self else { return }
                #if DEBUG
                cmuxDebugLog("mobile.observer tabs sink fired count=\(tabs.count)")
                #endif
                self.refreshPerWorkspaceSubscriptions(tabs: tabs)
                self.emitIfNeeded(force: false)
            }
        // Selection changes (Mac user clicks a different sidebar tab) need
        // to push to iPhone too. iPhone's selectedWorkspaceID drives which
        // terminal it displays.
        selectionCancellable = tabManager.$selectedTabId
            .throttle(for: .milliseconds(throttleMilliseconds), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.emitIfNeeded(force: false)
            }

        refreshPerWorkspaceSubscriptions(tabs: tabManager.tabs)
    }

    private func refreshPerWorkspaceSubscriptions(tabs: [Workspace]) {
        let currentIDs = Set(tabs.map(\.id))
        // Drop subscriptions for workspaces that vanished.
        for id in perWorkspaceCancellables.keys where !currentIDs.contains(id) {
            perWorkspaceCancellables.removeValue(forKey: id)
        }
        // Merge the per-workspace publishers behind the mobile workspace
        // list: terminal set, terminal titles, workspace title, and displayed
        // directory fields. Directory changes can arrive from shell prompt
        // updates without changing the terminal set.
        for workspace in tabs where perWorkspaceCancellables[workspace.id] == nil {
            let publishers: [AnyPublisher<Void, Never>] = [
                workspace.$panels.map { _ in () }.eraseToAnyPublisher(),
                workspace.$panelTitles.map { _ in () }.eraseToAnyPublisher(),
                workspace.$title.map { _ in () }.eraseToAnyPublisher(),
                workspace.$currentDirectory.map { _ in () }.eraseToAnyPublisher(),
                workspace.$panelDirectories.map { _ in () }.eraseToAnyPublisher(),
            ]
            let merged = Publishers.MergeMany(publishers)
                .throttle(for: .milliseconds(throttleMilliseconds), scheduler: RunLoop.main, latest: true)
            perWorkspaceCancellables[workspace.id] = merged.sink { [weak self] _ in
                self?.emitIfNeeded(force: false)
            }
        }
    }

    private func emitIfNeeded(force: Bool) {
        guard let tabManager else { return }
        let hash = Self.summaryHash(for: tabManager.tabs, selectedTabID: tabManager.selectedTabId)
        if !force, hash == lastSummaryHash {
            #if DEBUG
            cmuxDebugLog("mobile.observer skip: hash unchanged=\(hash) tabs=\(tabManager.tabs.count)")
            #endif
            return
        }
        lastSummaryHash = hash
        mobileWorkspaceObserverLog.debug("emitting workspace.updated (hash=\(hash, privacy: .public))")
        #if DEBUG
        cmuxDebugLog("mobile.observer EMIT workspace.updated hash=\(hash) tabs=\(tabManager.tabs.count) force=\(force)")
        #endif
        MobileHostService.shared.emitEvent(topic: "workspace.updated", payload: [:])
    }

    /// Stable hash of the iOS-facing shape: workspace ids + titles + their
    /// panel id sets + panel titles. Mutations that don't show up on the
    /// mobile list (pane geometry, scrollback content, focus only) don't
    /// trip the event, so we don't fan out on every keystroke.
    private static func summaryHash(for tabs: [Workspace], selectedTabID: UUID?) -> Int {
        var hasher = Hasher()
        hasher.combine(tabs.count)
        hasher.combine(selectedTabID)
        for workspace in tabs {
            hasher.combine(workspace.id)
            hasher.combine(workspace.title)
            // Terminal/panel set + their titles. Sort panel ids so insertion
            // order quirks don't manufacture spurious diffs.
            let panelIDs = workspace.panels.keys.sorted()
            hasher.combine(panelIDs)
            for id in panelIDs {
                hasher.combine(workspace.panelTitles[id])
                hasher.combine(workspace.panelDirectories[id])
            }
            hasher.combine(workspace.currentDirectory)
            for id in workspace.panelDirectories.keys.sorted() {
                hasher.combine(id)
                hasher.combine(workspace.panelDirectories[id])
            }
        }
        return hasher.finalize()
    }

    #if DEBUG
    static func summaryHashForTesting(tabs: [Workspace], selectedTabID: UUID?) -> Int {
        summaryHash(for: tabs, selectedTabID: selectedTabID)
    }
    #endif
}
