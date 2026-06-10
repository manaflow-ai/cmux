import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CmuxFileWatch
import CmuxGit
import CmuxProcess
import CoreVideo
import Combine
import CoreServices
import Darwin
import OSLog


// MARK: - Focus History
extension TabManager {
    @discardableResult
    func withFocusHistoryRecordingSuppressed<Result>(_ body: () throws -> Result) rethrows -> Result {
        focusHistoryRecordingSuppressionDepth += 1
        defer {
            focusHistoryRecordingSuppressionDepth = max(0, focusHistoryRecordingSuppressionDepth - 1)
        }
        return try body()
    }

    func recordFocusInHistory(
        workspaceId: UUID,
        panelId: UUID?,
        preservingForwardBranch: Bool = false
    ) {
        guard shouldRecordFocusHistory else { return }
        let entry = FocusHistoryEntry(workspaceId: workspaceId, panelId: panelId)
        guard focusHistoryEntryIsValid(entry) else { return }

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
                        focusHistoryRevision &+= 1
                    }
                    return
                }

                focusHistory.insert(FocusHistoryRecord(entry: entry), at: insertionIndex)
                let overflow = max(0, focusHistory.count - maxHistorySize)
                if overflow > 0 {
                    focusHistory.removeFirst(overflow)
                }
                historyIndex = max(-1, insertionIndex - overflow)
                focusHistoryRevision &+= 1
                return
            } else {
                focusHistory = Array(focusHistory.prefix(historyIndex + 1))
                didMutateHistory = true
            }
        }

        if focusHistory.last?.entry == entry {
            historyIndex = focusHistory.count - 1
            if didMutateHistory {
                focusHistoryRevision &+= 1
            }
            return
        }

        focusHistory.append(FocusHistoryRecord(entry: entry))
        if focusHistory.count > maxHistorySize {
            focusHistory.removeFirst(focusHistory.count - maxHistorySize)
        }

        historyIndex = focusHistory.count - 1
        focusHistoryRevision &+= 1
    }

    func recordFocusInHistory(
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

    func recordImplicitFocusInHistory(workspaceId: UUID, panelId: UUID?) {
        guard shouldRecordFocusHistory else { return }
        let entry = FocusHistoryEntry(workspaceId: workspaceId, panelId: panelId)
        guard focusHistoryEntryIsValid(entry) else { return }

        if historyIndex >= 0,
           historyIndex < focusHistory.count - 1,
           focusHistory[historyIndex].entry.workspaceId == workspaceId {
            if focusHistory[historyIndex].entry != entry {
                focusHistory[historyIndex] = FocusHistoryRecord(entry: entry)
                focusHistoryRevision &+= 1
            }
            return
        }

        recordFocusInHistory(workspaceId: workspaceId, panelId: panelId)
    }

    func invalidateFocusHistoryTarget(workspaceId: UUID, panelId: UUID?) {
        if let panelId {
            guard focusHistory.contains(where: { $0.entry.workspaceId == workspaceId && $0.entry.panelId == panelId }) else {
                return
            }
            focusHistoryRevision &+= 1
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
        focusHistoryRevision &+= 1
    }

    func panelIdForFocusHistorySurface(_ surfaceId: UUID, workspaceId: UUID) -> UUID {
        tabs.first(where: { $0.id == workspaceId })?.panelIdFromSurfaceId(TabID(uuid: surfaceId)) ?? surfaceId
    }

    private func focusHistoryEntryIsValid(_ entry: FocusHistoryEntry) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == entry.workspaceId }) else { return false }
        guard let panelId = entry.panelId else { return true }
        return workspace.panels[panelId] != nil
    }

    private func focusHistoryWorkspace(for entry: FocusHistoryEntry) -> Workspace? {
        tabs.first(where: { $0.id == entry.workspaceId })
    }

    func resolvedFocusHistoryPanelId(for entry: FocusHistoryEntry, in workspace: Workspace) -> UUID? {
        if let panelId = entry.panelId, workspace.panels[panelId] != nil {
            return panelId
        }

        if let rememberedPanelId = focusedPanelId(for: workspace.id),
           workspace.panels[rememberedPanelId] != nil {
            return rememberedPanelId
        }

        if let workspacePanelId = workspace.focusedPanelId,
           workspace.panels[workspacePanelId] != nil {
            return workspacePanelId
        }

        return workspace.panels.keys.sorted { $0.uuidString < $1.uuidString }.first
    }

    var currentFocusHistoryEntry: FocusHistoryEntry? {
        guard let selectedTabId else { return nil }
        return FocusHistoryEntry(workspaceId: selectedTabId, panelId: focusedPanelId(for: selectedTabId))
    }

    private func resolvedFocusHistoryEntry(for entry: FocusHistoryEntry) -> FocusHistoryEntry? {
        guard let workspace = focusHistoryWorkspace(for: entry) else { return nil }
        // Closed panels still leave a useful workspace-level history entry.
        // Resolve them to the workspace's current remembered panel instead of
        // discarding the user's ability to jump back to that workspace.
        return FocusHistoryEntry(
            workspaceId: workspace.id,
            panelId: resolvedFocusHistoryPanelId(for: entry, in: workspace)
        )
    }

    private func focusHistoryEntryResolvesToCurrent(_ entry: FocusHistoryEntry, currentEntry: FocusHistoryEntry?) -> Bool {
        guard let currentEntry,
              let resolvedEntry = resolvedFocusHistoryEntry(for: entry) else { return false }
        return resolvedEntry == currentEntry
    }

    private func focusHistoryEntryIsNavigable(_ entry: FocusHistoryEntry, currentEntry: FocusHistoryEntry?) -> Bool {
        guard resolvedFocusHistoryEntry(for: entry) != nil else { return false }
        if focusHistoryEntryResolvesToCurrent(entry, currentEntry: currentEntry) { return false }
        return true
    }

    func focusHistoryMenuSnapshot(
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

        let items = historyIndices.compactMap { index -> FocusHistoryMenuItem? in
            let record = focusHistory[index]
            let entry = record.entry
            guard let resolvedEntry = resolvedFocusHistoryEntry(for: entry),
                  let workspace = focusHistoryWorkspace(for: resolvedEntry),
                  focusHistoryEntryIsNavigable(entry, currentEntry: currentEntry) else {
                return nil
            }

            let workspaceTitle = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let panelTitle = resolvedEntry.panelId
                .flatMap { workspace.panelTitle(panelId: $0) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let position: FocusHistoryMenuPosition = direction == .back ? .older : .newer

            return FocusHistoryMenuItem(
                historyIndex: index,
                entry: entry,
                workspaceTitle: workspaceTitle,
                panelTitle: panelTitle?.isEmpty == true ? nil : panelTitle,
                position: position,
                focusedAt: record.focusedAt,
                isNavigable: true
            )
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

    @discardableResult
    private func restoreFocusHistoryEntry(_ entry: FocusHistoryEntry) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == entry.workspaceId }) else { return false }

        if selectedTabId != workspace.id {
            selectedTabId = workspace.id
        }

        let targetPanelId = resolvedFocusHistoryPanelId(for: entry, in: workspace)

        if let targetPanelId {
            rememberFocusedSurface(tabId: workspace.id, surfaceId: targetPanelId)
            workspace.focusPanel(targetPanelId)
            workspace.triggerFocusFlash(panelId: targetPanelId)
        } else {
            focusSelectedTabPanel(previousTabId: nil)
        }

        return true
    }

    @discardableResult
    private func navigateToFocusHistoryEntry(_ entry: FocusHistoryEntry, targetIndex: Int) -> Bool {
        var didNavigate = false
        defer {
            if didNavigate {
                focusHistoryRevision &+= 1
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
    func navigateToFocusHistoryMenuItem(_ item: FocusHistoryMenuItem) -> Bool {
        guard focusHistoryEntryIsNavigable(item.entry, currentEntry: currentFocusHistoryEntry) else { return false }
        var targetIndex = item.historyIndex
        guard focusHistory.indices.contains(targetIndex), focusHistory[targetIndex].entry == item.entry else {
            guard let fallbackIndex = focusHistory.lastIndex(where: { $0.entry == item.entry }) else { return false }
            targetIndex = fallbackIndex
            return navigateToFocusHistoryEntry(item.entry, targetIndex: targetIndex)
        }
        return navigateToFocusHistoryEntry(focusHistory[targetIndex].entry, targetIndex: targetIndex)
    }

    @discardableResult
    func navigateBack() -> Bool {
        guard historyIndex > 0 else { return false }

        let currentEntry = currentFocusHistoryEntry
        var targetIndex = historyIndex - 1
        while targetIndex >= 0 {
            let entry = focusHistory[targetIndex].entry
            guard focusHistoryWorkspace(for: entry) != nil else {
                focusHistory.remove(at: targetIndex)
                historyIndex -= 1
                targetIndex -= 1
                focusHistoryRevision &+= 1
                continue
            }
            if focusHistoryEntryResolvesToCurrent(entry, currentEntry: currentEntry) {
                targetIndex -= 1
                continue
            }
            if navigateToFocusHistoryEntry(entry, targetIndex: targetIndex) {
                return true
            }
            focusHistory.remove(at: targetIndex)
            historyIndex -= 1
            targetIndex -= 1
            focusHistoryRevision &+= 1
        }
        return false
    }

    @discardableResult
    func navigateForward() -> Bool {
        guard historyIndex < focusHistory.count - 1 else { return false }

        let currentEntry = currentFocusHistoryEntry
        var targetIndex = historyIndex + 1
        while targetIndex < focusHistory.count {
            let entry = focusHistory[targetIndex].entry
            guard focusHistoryWorkspace(for: entry) != nil else {
                focusHistory.remove(at: targetIndex)
                focusHistoryRevision &+= 1
                continue
            }
            if focusHistoryEntryResolvesToCurrent(entry, currentEntry: currentEntry) {
                targetIndex += 1
                continue
            }
            if navigateToFocusHistoryEntry(entry, targetIndex: targetIndex) {
                return true
            }
            focusHistory.remove(at: targetIndex)
            focusHistoryRevision &+= 1
        }
        return false
    }

    var canNavigateBack: Bool {
        let currentEntry = currentFocusHistoryEntry
        return historyIndex > 0 && focusHistory.prefix(historyIndex).contains { record in
            focusHistoryEntryIsNavigable(record.entry, currentEntry: currentEntry)
        }
    }

    var canNavigateForward: Bool {
        let currentEntry = currentFocusHistoryEntry
        return historyIndex < focusHistory.count - 1 && focusHistory.suffix(from: historyIndex + 1).contains { record in
            focusHistoryEntryIsNavigable(record.entry, currentEntry: currentEntry)
        }
    }

    // MARK: - Split Operations (Backwards Compatibility)

}
