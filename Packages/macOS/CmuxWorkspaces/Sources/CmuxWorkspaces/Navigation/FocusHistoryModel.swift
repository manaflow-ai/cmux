public import Foundation
import Observation

/// Per-window focus-history sub-model: the back/forward stack of
/// workspace/panel focus positions TabManager used to keep inline, plus the
/// recording-suppression depth and the deferred-selection suppression marks.
///
/// `@MainActor` because every entry point is a MainActor UI path (workspace
/// selection `didSet`, the surface-focus observer, menu and shortcut
/// navigation) — state lives where its callers live. Reads and writes go
/// through ``FocusHistoryHosting`` synchronously inside one turn, preserving
/// the legacy interleavings exactly: selecting a workspace during
/// navigation synchronously re-enters this model through the host's
/// selection `didSet`, which is why suppression depth and the stack live on
/// one isolation domain. Bodies are lifted one-for-one from
/// `Sources/TabManager.swift`; only the host-seam spellings changed.
@MainActor
@Observable
public final class FocusHistoryModel: FocusHistoryNavigating {
    // The window-side seam; set once via attach(host:). Weak: the host
    // (the per-window TabManager) owns the model.
    private(set) weak var host: (any FocusHistoryHosting)?

    // Recent focus history for back/forward navigation across workspaces
    // and panes.
    private var focusHistory: [FocusHistoryRecord] = []
    private var historyIndex: Int = -1
    private var focusHistoryRecordingSuppressionDepth = 0
    private var focusHistorySuppressedSelectionSideEffectGenerations: Set<UInt64> = []
    private let maxHistorySize: Int
    private let now: @MainActor () -> Date
    private let navigationScope: @MainActor () -> FocusHistoryNavigationScope

    /// Creates a detached model; call ``attach(host:)`` before use.
    ///
    /// - Parameters:
    ///   - maxHistorySize: The legacy stack cap (50).
    ///   - now: Supplies the timestamp for newly recorded focus entries.
    ///   - navigationScope: Supplies the current navigation scope. The model
    ///     reads it for each operation so a settings change applies without
    ///     rebuilding or clearing the recorded history.
    public init(
        maxHistorySize: Int = 50,
        now: @escaping @MainActor () -> Date = Date.init,
        navigationScope: @escaping @MainActor () -> FocusHistoryNavigationScope = { .panesAndTabs }
    ) {
        self.maxHistorySize = maxHistorySize
        self.now = now
        self.navigationScope = navigationScope
    }

    public func attach(host: any FocusHistoryHosting) {
        self.host = host
    }

    public var shouldRecordFocusHistory: Bool {
        focusHistoryRecordingSuppressionDepth == 0
    }

    @discardableResult
    public func withFocusHistoryRecordingSuppressed<Result>(_ body: () throws -> Result) rethrows -> Result {
        focusHistoryRecordingSuppressionDepth += 1
        defer {
            focusHistoryRecordingSuppressionDepth = max(0, focusHistoryRecordingSuppressionDepth - 1)
        }
        return try body()
    }

    public func markSuppressedSelectionSideEffectGeneration(_ generation: UInt64) {
        focusHistorySuppressedSelectionSideEffectGenerations.insert(generation)
    }

    public func consumeSuppressedSelectionSideEffectGeneration(_ generation: UInt64) -> Bool {
        focusHistorySuppressedSelectionSideEffectGenerations.remove(generation) != nil
    }

    public func reset() {
        focusHistory.removeAll()
        historyIndex = -1
        focusHistoryRecordingSuppressionDepth = 0
        focusHistorySuppressedSelectionSideEffectGenerations.removeAll()
    }

    // MARK: - Recording

    public func recordFocusInHistory(
        workspaceId: UUID,
        panelId: UUID?,
        preservingForwardBranch: Bool = false
    ) {
        guard shouldRecordFocusHistory else { return }
        let entry = FocusHistoryEntry(workspaceId: workspaceId, panelId: panelId)
        guard focusHistoryEntryIsValid(entry) else { return }

        if navigationScope() == .workspacesOnly,
           historyIndex >= 0,
           historyIndex < focusHistory.count,
           focusHistory[historyIndex].entry.workspaceId == workspaceId {
            if focusHistory[historyIndex].entry != entry {
                focusHistory[historyIndex] = FocusHistoryRecord(entry: entry, focusedAt: now())
                host?.focusHistoryRevisionDidChange()
            }
            return
        }

        if historyIndex >= 0,
           historyIndex < focusHistory.count,
           focusHistory[historyIndex].entry == entry {
            return
        }

        var didMutateHistory = false
        if historyIndex < focusHistory.count - 1 {
            if preservingForwardBranch {
                let insertionIndex = max(0, historyIndex + 1)
                if focusHistory[insertionIndex].entry == entry {
                    let oldHistoryIndex = historyIndex
                    historyIndex = insertionIndex
                    if historyIndex != oldHistoryIndex {
                        host?.focusHistoryRevisionDidChange()
                    }
                    return
                }

                focusHistory.insert(FocusHistoryRecord(entry: entry, focusedAt: now()), at: insertionIndex)
                let overflow = max(0, focusHistory.count - maxHistorySize)
                if overflow > 0 {
                    focusHistory.removeFirst(overflow)
                }
                historyIndex = max(-1, insertionIndex - overflow)
                host?.focusHistoryRevisionDidChange()
                return
            } else {
                focusHistory = Array(focusHistory.prefix(historyIndex + 1))
                didMutateHistory = true
            }
        }

        if focusHistory.last?.entry == entry {
            historyIndex = focusHistory.count - 1
            if didMutateHistory {
                host?.focusHistoryRevisionDidChange()
            }
            return
        }

        focusHistory.append(FocusHistoryRecord(entry: entry, focusedAt: now()))
        if focusHistory.count > maxHistorySize {
            focusHistory.removeFirst(focusHistory.count - maxHistorySize)
        }

        historyIndex = focusHistory.count - 1
        host?.focusHistoryRevisionDidChange()
    }

    public func recordFocusInHistory(
        _ entry: FocusHistoryEntry?,
        preservingForwardBranch: Bool = false
    ) {
        guard let entry else { return }
        recordFocusInHistory(
            workspaceId: entry.workspaceId,
            panelId: entry.panelId,
            preservingForwardBranch: preservingForwardBranch
        )
    }

    public func recordImplicitFocusInHistory(workspaceId: UUID, panelId: UUID?) {
        guard shouldRecordFocusHistory else { return }
        let entry = FocusHistoryEntry(workspaceId: workspaceId, panelId: panelId)
        guard focusHistoryEntryIsValid(entry) else { return }

        if historyIndex >= 0,
           historyIndex < focusHistory.count - 1,
           focusHistory[historyIndex].entry.workspaceId == workspaceId {
            if focusHistory[historyIndex].entry != entry {
                focusHistory[historyIndex] = FocusHistoryRecord(entry: entry, focusedAt: now())
                host?.focusHistoryRevisionDidChange()
            }
            return
        }

        recordFocusInHistory(workspaceId: workspaceId, panelId: panelId)
    }

    // MARK: - Invalidation

    public func invalidateFocusHistoryTarget(workspaceId: UUID, panelId: UUID?) {
        if let panelId {
            guard focusHistory.contains(where: { $0.entry.workspaceId == workspaceId && $0.entry.panelId == panelId }) else {
                return
            }
            host?.focusHistoryRevisionDidChange()
            return
        }

        let oldCount = focusHistory.count
        guard oldCount > 0 else { return }

        let currentIndex = historyIndex
        let removedBeforeOrAtCurrent = focusHistory
            .prefix(max(0, min(currentIndex + 1, oldCount)))
            .filter { $0.entry.workspaceId == workspaceId }
            .count
        focusHistory.removeAll { $0.entry.workspaceId == workspaceId }
        guard focusHistory.count != oldCount else { return }

        historyIndex -= removedBeforeOrAtCurrent
        if focusHistory.isEmpty {
            historyIndex = -1
        } else {
            historyIndex = min(max(-1, historyIndex), focusHistory.count - 1)
        }
        host?.focusHistoryRevisionDidChange()
    }

    // MARK: - Resolution

    private func focusHistoryEntryIsValid(_ entry: FocusHistoryEntry) -> Bool {
        guard host?.workspaceExists(entry.workspaceId) == true else { return false }
        guard let panelId = entry.panelId else { return true }
        return host?.panelExists(workspaceId: entry.workspaceId, panelId: panelId) == true
    }

    public func resolvedFocusHistoryPanelId(for entry: FocusHistoryEntry) -> UUID? {
        guard let host else { return nil }
        let workspaceId = entry.workspaceId

        if let panelId = entry.panelId, host.panelExists(workspaceId: workspaceId, panelId: panelId) {
            return panelId
        }

        if let rememberedPanelId = host.rememberedFocusedPanelId(workspaceId),
           host.panelExists(workspaceId: workspaceId, panelId: rememberedPanelId) {
            return rememberedPanelId
        }

        if let workspacePanelId = host.workspaceFocusedPanelId(workspaceId),
           host.panelExists(workspaceId: workspaceId, panelId: workspacePanelId) {
            return workspacePanelId
        }

        return host.firstPanelIdSortedByUUIDString(workspaceId)
    }

    public var currentFocusHistoryEntry: FocusHistoryEntry? {
        guard let selectedWorkspaceId = host?.selectedWorkspaceId else { return nil }
        return FocusHistoryEntry(
            workspaceId: selectedWorkspaceId,
            panelId: host?.rememberedFocusedPanelId(selectedWorkspaceId)
        )
    }

    private func resolvedFocusHistoryEntry(for entry: FocusHistoryEntry) -> FocusHistoryEntry? {
        guard host?.workspaceExists(entry.workspaceId) == true else { return nil }
        // Closed panels still leave a useful workspace-level history entry.
        // Resolve them to the workspace's current remembered panel instead of
        // discarding the user's ability to jump back to that workspace.
        return FocusHistoryEntry(
            workspaceId: entry.workspaceId,
            panelId: resolvedFocusHistoryPanelId(for: entry)
        )
    }

    private func focusHistoryEntryIsNavigable(_ entry: FocusHistoryEntry, currentEntry: FocusHistoryEntry?) -> Bool {
        let scope = navigationScope()
        guard let resolvedEntry = resolvedFocusHistoryEntry(for: entry) else { return false }
        return focusHistoryEntryIsNavigable(
            entry: entry,
            resolvedEntry: resolvedEntry,
            scope: scope,
            currentEntry: currentEntry
        )
    }

    private func focusHistoryEntryIsNavigable(
        entry: FocusHistoryEntry,
        resolvedEntry: FocusHistoryEntry,
        scope: FocusHistoryNavigationScope,
        currentEntry: FocusHistoryEntry?
    ) -> Bool {
        if scope == .workspacesOnly,
           entry.workspaceId == currentEntry?.workspaceId {
            return false
        }
        if let currentEntry, resolvedEntry == currentEntry { return false }
        return true
    }

    private func navigationEntry(for entry: FocusHistoryEntry) -> FocusHistoryEntry {
        guard navigationScope() == .workspacesOnly else { return entry }
        return FocusHistoryEntry(workspaceId: entry.workspaceId, panelId: nil)
    }

    private func focusHistoryMenuItem(
        record: FocusHistoryRecord,
        historyIndex: Int,
        direction: FocusHistoryMenuDirection,
        scope: FocusHistoryNavigationScope,
        currentEntry: FocusHistoryEntry?
    ) -> FocusHistoryMenuItem? {
        let entry = record.entry
        let scopedEntry = scope == .workspacesOnly
            ? FocusHistoryEntry(workspaceId: entry.workspaceId, panelId: nil)
            : entry
        guard let resolvedEntry = resolvedFocusHistoryEntry(for: scopedEntry),
              let rawWorkspaceTitle = host?.workspaceTitle(resolvedEntry.workspaceId),
              focusHistoryEntryIsNavigable(
                  entry: scopedEntry,
                  resolvedEntry: resolvedEntry,
                  scope: scope,
                  currentEntry: currentEntry
              ) else {
            return nil
        }

        let workspaceTitle = rawWorkspaceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let panelTitle = scope == .workspacesOnly
            ? nil
            : resolvedEntry.panelId
                .flatMap { host?.panelTitle(workspaceId: resolvedEntry.workspaceId, panelId: $0) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        return FocusHistoryMenuItem(
            historyIndex: historyIndex,
            entry: scopedEntry,
            workspaceTitle: workspaceTitle,
            panelTitle: panelTitle?.isEmpty == true ? nil : panelTitle,
            position: direction == .back ? .older : .newer,
            focusedAt: record.focusedAt,
            isNavigable: true
        )
    }

    // MARK: - Menu snapshots

    public func focusHistoryMenuSnapshot(
        direction: FocusHistoryMenuDirection,
        maxItemCount: Int? = nil
    ) -> FocusHistoryMenuSnapshot {
        let currentEntry = currentFocusHistoryEntry
        let historyIndices: [Int]
        switch direction {
        case .back:
            let lastBackIndex = min(historyIndex, focusHistory.count) - 1
            historyIndices = lastBackIndex >= 0
                ? Array(stride(from: lastBackIndex, through: 0, by: -1))
                : []
        case .forward:
            historyIndices = historyIndex < focusHistory.count - 1
                ? Array((historyIndex + 1)..<focusHistory.count)
                : []
        }

        let scope = navigationScope()
        var previousWorkspaceId: UUID?
        let items = historyIndices.compactMap { index -> FocusHistoryMenuItem? in
            let record = focusHistory[index]
            guard let item = focusHistoryMenuItem(
                record: record,
                historyIndex: index,
                direction: direction,
                scope: scope,
                currentEntry: currentEntry
            ) else { return nil }
            if scope == .workspacesOnly, previousWorkspaceId == record.entry.workspaceId {
                return nil
            }
            previousWorkspaceId = record.entry.workspaceId
            return item
        }
        if let maxItemCount, maxItemCount >= 0, items.count > maxItemCount {
            return FocusHistoryMenuSnapshot(
                items: Array(items.prefix(maxItemCount)),
                totalItemCount: items.count,
                isLimited: true
            )
        }

        return FocusHistoryMenuSnapshot(
            items: items,
            totalItemCount: items.count,
            isLimited: false
        )
    }

    /// Builds the recency-ordered rows shared by the main History menu.
    /// Raw records are sorted before resolving host state, which keeps the
    /// lookup work bounded to the rendered limit without relying on index
    /// order after an in-place timestamp rewrite.
    public func recentlyFocusedFocusHistoryMenuItems(maxItemCount: Int) -> [FocusHistoryMenuItem] {
        let limit = max(0, maxItemCount)
        guard limit > 0 else { return [] }

        let currentEntry = currentFocusHistoryEntry
        let scope = navigationScope()

        // Filter consecutive workspace duplicates in each direction before
        // sorting. The final sort is by the stored timestamp rather than index:
        // recordFocusInHistory can rewrite a mid-stack timestamp in place.
        var candidates: [(index: Int, record: FocusHistoryRecord, direction: FocusHistoryMenuDirection)] = []
        var previousBackWorkspaceId: UUID?
        if historyIndex > 0 {
            for index in stride(from: historyIndex - 1, through: 0, by: -1) {
                let record = focusHistory[index]
                if scope == .workspacesOnly,
                   previousBackWorkspaceId == record.entry.workspaceId {
                    continue
                }
                previousBackWorkspaceId = record.entry.workspaceId
                candidates.append((index: index, record: record, direction: .back))
            }
        }

        var previousForwardWorkspaceId: UUID?
        if historyIndex < focusHistory.count - 1 {
            for index in (historyIndex + 1)..<focusHistory.count {
                let record = focusHistory[index]
                if scope == .workspacesOnly,
                   previousForwardWorkspaceId == record.entry.workspaceId {
                    continue
                }
                previousForwardWorkspaceId = record.entry.workspaceId
                candidates.append((index: index, record: record, direction: .forward))
            }
        }

        candidates.sort { lhs, rhs in
            if lhs.record.focusedAt == rhs.record.focusedAt {
                return lhs.index > rhs.index
            }
            return lhs.record.focusedAt > rhs.record.focusedAt
        }

        var items: [FocusHistoryMenuItem] = []
        items.reserveCapacity(limit)
        for candidate in candidates {
            guard let item = focusHistoryMenuItem(
                record: candidate.record,
                historyIndex: candidate.index,
                direction: candidate.direction,
                scope: scope,
                currentEntry: currentEntry
            ) else {
                continue
            }
            items.append(item)
            if items.count == limit {
                break
            }
        }
        return items
    }

    // MARK: - Navigation

    @discardableResult
    private func restoreFocusHistoryEntry(_ entry: FocusHistoryEntry) -> Bool {
        guard let host, host.workspaceExists(entry.workspaceId) else { return false }

        host.selectWorkspace(entry.workspaceId)

        let targetPanelId = resolvedFocusHistoryPanelId(for: entry)

        if let targetPanelId {
            host.rememberFocusedSurface(workspaceId: entry.workspaceId, surfaceId: targetPanelId)
            host.focusPanel(workspaceId: entry.workspaceId, panelId: targetPanelId)
            host.triggerFocusFlash(workspaceId: entry.workspaceId, panelId: targetPanelId)
        } else {
            host.focusSelectedWorkspacePanel()
        }

        return true
    }

    @discardableResult
    private func navigateToFocusHistoryEntry(_ entry: FocusHistoryEntry, targetIndex: Int) -> Bool {
        var didNavigate = false
        defer {
            if didNavigate {
                host?.focusHistoryRevisionDidChange()
            }
        }

        var didRestore = false
        withFocusHistoryRecordingSuppressed {
            didRestore = restoreFocusHistoryEntry(entry)
        }
        guard didRestore else { return false }
        historyIndex = targetIndex
        didNavigate = true
        return true
    }

    @discardableResult
    public func navigateToFocusHistoryMenuItem(_ item: FocusHistoryMenuItem) -> Bool {
        guard focusHistoryEntryIsNavigable(item.entry, currentEntry: currentFocusHistoryEntry) else { return false }
        var targetIndex = item.historyIndex
        if navigationScope() == .workspacesOnly {
            guard focusHistory.indices.contains(targetIndex),
                  focusHistory[targetIndex].entry.workspaceId == item.entry.workspaceId else {
                guard let fallbackIndex = focusHistory.lastIndex(where: {
                    $0.entry.workspaceId == item.entry.workspaceId
                }) else { return false }
                targetIndex = fallbackIndex
                return navigateToFocusHistoryEntry(item.entry, targetIndex: targetIndex)
            }
            return navigateToFocusHistoryEntry(item.entry, targetIndex: targetIndex)
        }
        guard focusHistory.indices.contains(targetIndex), focusHistory[targetIndex].entry == item.entry else {
            guard let fallbackIndex = focusHistory.lastIndex(where: { $0.entry == item.entry }) else { return false }
            targetIndex = fallbackIndex
            return navigateToFocusHistoryEntry(item.entry, targetIndex: targetIndex)
        }
        return navigateToFocusHistoryEntry(focusHistory[targetIndex].entry, targetIndex: targetIndex)
    }

    @discardableResult
    public func navigateBack() -> Bool {
        guard historyIndex > 0 else { return false }

        let currentEntry = currentFocusHistoryEntry
        var targetIndex = historyIndex - 1
        while targetIndex >= 0 {
            let entry = focusHistory[targetIndex].entry
            guard host?.workspaceExists(entry.workspaceId) == true else {
                focusHistory.remove(at: targetIndex)
                historyIndex -= 1
                targetIndex -= 1
                host?.focusHistoryRevisionDidChange()
                continue
            }
            if !focusHistoryEntryIsNavigable(entry, currentEntry: currentEntry) {
                targetIndex -= 1
                continue
            }
            if navigateToFocusHistoryEntry(navigationEntry(for: entry), targetIndex: targetIndex) {
                return true
            }
            focusHistory.remove(at: targetIndex)
            historyIndex -= 1
            targetIndex -= 1
            host?.focusHistoryRevisionDidChange()
        }
        return false
    }

    @discardableResult
    public func navigateForward() -> Bool {
        guard historyIndex < focusHistory.count - 1 else { return false }

        let currentEntry = currentFocusHistoryEntry
        var targetIndex = historyIndex + 1
        while targetIndex < focusHistory.count {
            let entry = focusHistory[targetIndex].entry
            guard host?.workspaceExists(entry.workspaceId) == true else {
                focusHistory.remove(at: targetIndex)
                host?.focusHistoryRevisionDidChange()
                continue
            }
            if !focusHistoryEntryIsNavigable(entry, currentEntry: currentEntry) {
                targetIndex += 1
                continue
            }
            if navigateToFocusHistoryEntry(navigationEntry(for: entry), targetIndex: targetIndex) {
                return true
            }
            focusHistory.remove(at: targetIndex)
            host?.focusHistoryRevisionDidChange()
        }
        return false
    }

    public var canNavigateBack: Bool {
        let currentEntry = currentFocusHistoryEntry
        return historyIndex > 0 && focusHistory.prefix(historyIndex).contains { record in
            focusHistoryEntryIsNavigable(record.entry, currentEntry: currentEntry)
        }
    }

    public var canNavigateForward: Bool {
        let currentEntry = currentFocusHistoryEntry
        return historyIndex < focusHistory.count - 1 && focusHistory.suffix(from: historyIndex + 1).contains { record in
            focusHistoryEntryIsNavigable(record.entry, currentEntry: currentEntry)
        }
    }
}
