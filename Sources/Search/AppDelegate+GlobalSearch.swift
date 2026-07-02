import AppKit
import CmuxCommandPalette
import Foundation

extension AppDelegate {
    func globalSearchPanelContexts() -> [GlobalSearchPanelContext] {
        var contexts: [GlobalSearchPanelContext] = []
        var seenPanelKeys = Set<String>()
        var windowOrdinal = 1
        var orderedWindowRanks: [UUID: Int] = [:]
        for window in NSApp.orderedWindows {
            guard let windowID = mainWindowId(from: window),
                  orderedWindowRanks[windowID] == nil else {
                continue
            }
            orderedWindowRanks[windowID] = orderedWindowRanks.count
        }

        func append(windowID: UUID, tabManager: TabManager, window: NSWindow?) {
            let fallbackWindowTitle = String(localized: "menu.windowNumber", defaultValue: "Window \(windowOrdinal)")
            windowOrdinal += 1
            let windowTitle = {
                let trimmed = window?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? fallbackWindowTitle : trimmed
            }()

            let orderedWorkspaces = tabManager.tabs.enumerated().sorted { lhs, rhs in
                let lhsSelected = lhs.element.id == tabManager.selectedTabId
                let rhsSelected = rhs.element.id == tabManager.selectedTabId
                if lhsSelected != rhsSelected { return lhsSelected }
                return lhs.offset < rhs.offset
            }.map(\.element)

            for workspace in orderedWorkspaces {
                let workspaceTitle = {
                    let trimmed = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty
                        ? String(localized: "workspace.displayName.fallback", defaultValue: "Workspace")
                        : trimmed
                }()

                let orderedPanelIDs = workspace.sidebarOrderedPanelIds()
                var seenPanelIDs = Set<UUID>()
                let remainingPanelIDs = workspace.panels.keys
                    .filter { !orderedPanelIDs.contains($0) }
                    .sorted { $0.uuidString < $1.uuidString }

                for panelID in orderedPanelIDs + remainingPanelIDs where seenPanelIDs.insert(panelID).inserted {
                    guard let panel = workspace.panels[panelID] else { continue }
                    let key = "\(windowID.uuidString):\(workspace.id.uuidString):\(panel.id.uuidString)"
                    guard seenPanelKeys.insert(key).inserted else { continue }
                    let panelTitle = panel.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    contexts.append(
                        GlobalSearchPanelContext(
                            windowID: windowID,
                            windowTitle: windowTitle,
                            workspaceID: workspace.id,
                            workspaceTitle: workspaceTitle,
                            panelID: panel.id,
                            panelTitle: panelTitle.isEmpty ? workspaceTitle : panelTitle,
                            panel: panel
                        )
                    )
                }
            }
        }

        let liveContexts = registeredMainWindows.sorted { lhs, rhs in
            let lhsRank = orderedWindowRanks[lhs.windowId] ?? Int.max
            let rhsRank = orderedWindowRanks[rhs.windowId] ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }

        for context in liveContexts {
            append(
                windowID: context.windowId,
                tabManager: context.tabManager,
                window: context.window ?? windowForMainWindowId(context.windowId)
            )
        }

        let recoverableRoutes = recoverableMainWindowRoutes().sorted { lhs, rhs in
            let lhsRank = orderedWindowRanks[lhs.windowId] ?? Int.max
            let rhsRank = orderedWindowRanks[rhs.windowId] ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }

        for route in recoverableRoutes {
            guard let tabManager = route.tabManager else { continue }
            let alreadySeen = contexts.contains { $0.windowID == route.windowId }
            guard !alreadySeen else { continue }
            append(windowID: route.windowId, tabManager: tabManager, window: route.window)
        }

        return contexts
    }

    func globalSearchContext(
        forPanelID panelID: UUID,
        preferredWorkspaceID: UUID?
    ) -> GlobalSearchPanelContext? {
        var fallback: GlobalSearchPanelContext?
        var seenWindowIDs = Set<UUID>()
        var windowOrdinal = 1

        func inspect(windowID: UUID, tabManager: TabManager, window: NSWindow?) -> GlobalSearchPanelContext? {
            _ = seenWindowIDs.insert(windowID)
            let fallbackWindowTitle = String(localized: "menu.windowNumber", defaultValue: "Window \(windowOrdinal)")
            windowOrdinal += 1
            let windowTitle = {
                let trimmed = window?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? fallbackWindowTitle : trimmed
            }()

            for workspace in tabManager.tabs {
                guard let panel = workspace.panels[panelID] else { continue }
                let workspaceTitle = {
                    let trimmed = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty
                        ? String(localized: "workspace.displayName.fallback", defaultValue: "Workspace")
                        : trimmed
                }()
                let panelTitle = panel.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let context = GlobalSearchPanelContext(
                    windowID: windowID,
                    windowTitle: windowTitle,
                    workspaceID: workspace.id,
                    workspaceTitle: workspaceTitle,
                    panelID: panel.id,
                    panelTitle: panelTitle.isEmpty ? workspaceTitle : panelTitle,
                    panel: panel
                )

                if preferredWorkspaceID == nil || workspace.id == preferredWorkspaceID {
                    return context
                }
                fallback = fallback ?? context
            }

            return nil
        }

        for context in registeredMainWindows {
            if let result = inspect(
                windowID: context.windowId,
                tabManager: context.tabManager,
                window: context.window ?? windowForMainWindowId(context.windowId)
            ) {
                return result
            }
        }

        for route in recoverableMainWindowRoutes() {
            guard !seenWindowIDs.contains(route.windowId),
                  let tabManager = route.tabManager else {
                continue
            }
            if let result = inspect(windowID: route.windowId, tabManager: tabManager, window: route.window) {
                return result
            }
        }

        return fallback
    }

    func openGlobalSearchHit(_ hit: SearchIndexHit, query: String) {
        let resolvedContext = hit.panelID.flatMap {
            globalSearchContext(forPanelID: $0, preferredWorkspaceID: hit.workspaceID)
        }
        let windowID = resolvedContext?.windowID ?? hit.windowID
        let workspaceID = resolvedContext?.workspaceID ?? hit.workspaceID

        guard let tabManager = tabManagerFor(windowId: windowID),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            NSSound.beep()
            return
        }

        _ = environment.mainWindowRouter.focusMainWindow(windowId: windowID)
        tabManager.selectTab(workspace)
        terminalControl.setActiveTabManager(tabManager)

        if let panelID = hit.panelID, workspace.panels[panelID] != nil {
            tabManager.focusSurface(tabId: workspace.id, surfaceId: panelID)
            if let browserPanel = workspace.browserPanel(for: panelID) {
                applyBrowserInlineSearch(query: query, hit: hit, to: browserPanel)
            } else if let markdownPanel = workspace.markdownPanel(for: panelID) {
                applyMarkdownInlineSearch(query: query, hit: hit, to: markdownPanel)
            }
        }
    }

    private func applyBrowserInlineSearch(query: String, hit: SearchIndexHit, to panel: BrowserPanel) {
        guard let needle = GlobalSearchInlineSearch.browserNeedle(for: query, hit: hit) else { return }
        if let searchState = panel.searchState {
            searchState.needle = needle
        } else {
            panel.searchState = BrowserSearchState(needle: needle)
        }
    }

    private func applyMarkdownInlineSearch(query: String, hit: SearchIndexHit, to panel: MarkdownPanel) {
        guard let needle = GlobalSearchInlineSearch.needle(for: query, hit: hit) else { return }
        panel.applySearchNeedle(needle)
    }
}

enum GlobalSearchInlineSearch {
    static func browserNeedle(for query: String, hit: SearchIndexHit) -> String? {
        needle(for: query, hit: hit)
    }

    static func needle(for query: String, hit: SearchIndexHit) -> String? {
        GlobalSearchNeedleResolver().needle(
            tokens: SearchIndex.queryTokens(for: query),
            hitText: GlobalSearchNeedleResolver.HitText(
                snippet: hit.snippet,
                title: hit.title,
                location: hit.location,
                anchor: hit.anchor
            )
        )
    }
}
