import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

let lastSurfaceCloseShortcutDefaultsKey = "closeWorkspaceOnLastSurfaceShortcut"

func drainMainQueue() {
    let expectation = XCTestExpectation(description: "drain main queue")
    DispatchQueue.main.async {
        expectation.fulfill()
    }
    XCTWaiter().wait(for: [expectation], timeout: 1.0)
}

@MainActor
final class TabManagerChildExitCloseTests: XCTestCase {
    func testChildExitOnLastPanelClosesSelectedWorkspaceAndKeepsIndexStable() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()

        manager.selectWorkspace(second)
        XCTAssertEqual(manager.selectedTabId, second.id)

        guard let secondPanelId = second.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        manager.closePanelAfterChildExited(tabId: second.id, surfaceId: secondPanelId)

        XCTAssertEqual(manager.tabs.map(\.id), [first.id, third.id])
        XCTAssertEqual(
            manager.selectedTabId,
            third.id,
            "Expected selection to stay at the same index after deleting the selected workspace"
        )
    }

    func testChildExitOnLastPanelInLastWorkspaceSelectsPreviousWorkspace() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()

        manager.selectWorkspace(second)
        XCTAssertEqual(manager.selectedTabId, second.id)

        guard let secondPanelId = second.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        manager.closePanelAfterChildExited(tabId: second.id, surfaceId: secondPanelId)

        XCTAssertEqual(manager.tabs.map(\.id), [first.id])
        XCTAssertEqual(
            manager.selectedTabId,
            first.id,
            "Expected previous workspace to be selected after closing the last-index workspace"
        )
    }

    func testChildExitOnNonLastPanelClosesOnlyPanel() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        guard let splitPanel = workspace.newTerminalSplit(from: initialPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panel to be created")
            return
        }

        let panelCountBefore = workspace.panels.count
        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: splitPanel.id)

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.tabs.first?.id, workspace.id)
        XCTAssertEqual(workspace.panels.count, panelCountBefore - 1)
        XCTAssertNotNil(workspace.panels[initialPanelId], "Expected sibling panel to remain")
    }
}


@MainActor
final class TabManagerWorkspaceOwnershipTests: XCTestCase {
    func testCloseWorkspaceIgnoresWorkspaceNotOwnedByManager() {
        let manager = TabManager()
        _ = manager.addWorkspace()
        let initialTabIds = manager.tabs.map(\.id)
        let initialSelectedTabId = manager.selectedTabId

        let externalWorkspace = Workspace(title: "External workspace")
        let externalPanelCountBefore = externalWorkspace.panels.count
        let externalPanelTitlesBefore = externalWorkspace.panelTitles

        manager.closeWorkspace(externalWorkspace)

        XCTAssertEqual(manager.tabs.map(\.id), initialTabIds)
        XCTAssertEqual(manager.selectedTabId, initialSelectedTabId)
        XCTAssertEqual(externalWorkspace.panels.count, externalPanelCountBefore)
        XCTAssertEqual(externalWorkspace.panelTitles, externalPanelTitlesBefore)
    }
}

@MainActor
final class TabManagerPullRequestProbeTests: XCTestCase {
    func testGitHubRepositorySlugsPrioritizeUpstreamThenOriginAndDeduplicate() {
        let output = """
        origin https://github.com/austinwang/cmux.git (fetch)
        origin https://github.com/austinwang/cmux.git (push)
        upstream git@github.com:manaflow-ai/cmux.git (fetch)
        upstream git@github.com:manaflow-ai/cmux.git (push)
        backup ssh://git@github.com/manaflow-ai/cmux.git (fetch)
        mirror https://gitlab.com/manaflow-ai/cmux.git (fetch)
        """

        XCTAssertEqual(
            TabManager.githubRepositorySlugs(fromGitRemoteVOutput: output),
            ["manaflow-ai/cmux", "austinwang/cmux"]
        )
    }

    func testPreferredPullRequestPrefersOpenOverMergedAndClosed() {
        let candidates = [
            TabManager.GitHubPullRequestProbeItem(
                number: 1889,
                state: "MERGED",
                url: "https://github.com/manaflow-ai/cmux/pull/1889",
                updatedAt: "2026-03-20T18:00:00Z"
            ),
            TabManager.GitHubPullRequestProbeItem(
                number: 1891,
                state: "OPEN",
                url: "https://github.com/manaflow-ai/cmux/pull/1891",
                updatedAt: "2026-03-19T18:00:00Z"
            ),
            TabManager.GitHubPullRequestProbeItem(
                number: 1800,
                state: "CLOSED",
                url: "https://github.com/manaflow-ai/cmux/pull/1800",
                updatedAt: "2026-03-21T18:00:00Z"
            ),
        ]

        XCTAssertEqual(
            TabManager.preferredPullRequest(from: candidates),
            candidates[1]
        )
    }

    func testPreferredPullRequestPrefersMostRecentlyUpdatedWithinSameStatus() {
        let olderOpen = TabManager.GitHubPullRequestProbeItem(
            number: 1880,
            state: "OPEN",
            url: "https://github.com/manaflow-ai/cmux/pull/1880",
            updatedAt: "2026-03-18T18:00:00Z"
        )
        let newerOpen = TabManager.GitHubPullRequestProbeItem(
            number: 1890,
            state: "OPEN",
            url: "https://github.com/manaflow-ai/cmux/pull/1890",
            updatedAt: "2026-03-20T18:00:00Z"
        )

        XCTAssertEqual(
            TabManager.preferredPullRequest(from: [olderOpen, newerOpen]),
            newerOpen
        )
    }

    func testPreferredPullRequestIgnoresMalformedCandidates() {
        let valid = TabManager.GitHubPullRequestProbeItem(
            number: 1888,
            state: "OPEN",
            url: "https://github.com/manaflow-ai/cmux/pull/1888",
            updatedAt: "2026-03-20T18:00:00Z"
        )

        XCTAssertEqual(
            TabManager.preferredPullRequest(from: [
                TabManager.GitHubPullRequestProbeItem(
                    number: 9999,
                    state: "WHATEVER",
                    url: "https://github.com/manaflow-ai/cmux/pull/9999",
                    updatedAt: "2026-03-21T18:00:00Z"
                ),
                TabManager.GitHubPullRequestProbeItem(
                    number: 10000,
                    state: "OPEN",
                    url: "not a url",
                    updatedAt: "2026-03-21T18:00:00Z"
                ),
                valid,
            ]),
            valid
        )
    }
}


@MainActor
final class TabManagerCloseWorkspacesWithConfirmationTests: XCTestCase {
    func testCloseWorkspacesWithConfirmationPromptsOnceAndClosesAcceptedWorkspaces() {
        let manager = TabManager()
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.setCustomTitle(tabId: manager.tabs[0].id, title: "Alpha")
        manager.setCustomTitle(tabId: second.id, title: "Beta")
        manager.setCustomTitle(tabId: third.id, title: "Gamma")

        var prompts: [(title: String, message: String, acceptCmdD: Bool)] = []
        manager.confirmCloseHandler = { title, message, acceptCmdD in
            prompts.append((title, message, acceptCmdD))
            return true
        }

        manager.closeWorkspacesWithConfirmation([manager.tabs[0].id, second.id], allowPinned: true)

        let expectedMessage = String(
            format: String(
                localized: "dialog.closeWorkspaces.message",
                defaultValue: "This will close %1$lld workspaces and all of their panels:\n%2$@"
            ),
            locale: .current,
            Int64(2),
            "• Alpha\n• Beta"
        )
        XCTAssertEqual(prompts.count, 1, "Expected a single confirmation prompt for multi-close")
        XCTAssertEqual(
            prompts.first?.title,
            String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?")
        )
        XCTAssertEqual(prompts.first?.message, expectedMessage)
        XCTAssertEqual(prompts.first?.acceptCmdD, false)
        XCTAssertEqual(manager.tabs.map(\.title), ["Gamma"])
    }

    func testCloseWorkspacesWithConfirmationKeepsWorkspacesWhenCancelled() {
        let manager = TabManager()
        let second = manager.addWorkspace()
        manager.setCustomTitle(tabId: manager.tabs[0].id, title: "Alpha")
        manager.setCustomTitle(tabId: second.id, title: "Beta")

        var prompts: [(title: String, message: String, acceptCmdD: Bool)] = []
        manager.confirmCloseHandler = { title, message, acceptCmdD in
            prompts.append((title, message, acceptCmdD))
            return false
        }

        manager.closeWorkspacesWithConfirmation([manager.tabs[0].id, second.id], allowPinned: true)

        let expectedMessage = String(
            format: String(
                localized: "dialog.closeWorkspacesWindow.message",
                defaultValue: "This will close the current window, its %1$lld workspaces, and all of their panels:\n%2$@"
            ),
            locale: .current,
            Int64(2),
            "• Alpha\n• Beta"
        )
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(
            prompts.first?.title,
            String(localized: "dialog.closeWindow.title", defaultValue: "Close window?")
        )
        XCTAssertEqual(prompts.first?.message, expectedMessage)
        XCTAssertEqual(prompts.first?.acceptCmdD, true)
        XCTAssertEqual(manager.tabs.map(\.title), ["Alpha", "Beta"])
    }

    func testCloseCurrentWorkspaceWithConfirmationUsesSidebarMultiSelection() {
        let manager = TabManager()
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.setCustomTitle(tabId: manager.tabs[0].id, title: "Alpha")
        manager.setCustomTitle(tabId: second.id, title: "Beta")
        manager.setCustomTitle(tabId: third.id, title: "Gamma")
        manager.selectWorkspace(second)
        manager.setSidebarSelectedWorkspaceIds([manager.tabs[0].id, second.id])

        var prompts: [(title: String, message: String, acceptCmdD: Bool)] = []
        manager.confirmCloseHandler = { title, message, acceptCmdD in
            prompts.append((title, message, acceptCmdD))
            return false
        }

        manager.closeCurrentWorkspaceWithConfirmation()

        let expectedMessage = String(
            format: String(
                localized: "dialog.closeWorkspaces.message",
                defaultValue: "This will close %1$lld workspaces and all of their panels:\n%2$@"
            ),
            locale: .current,
            Int64(2),
            "• Alpha\n• Beta"
        )
        XCTAssertEqual(prompts.count, 1, "Expected Cmd+Shift+W path to reuse the multi-close summary dialog")
        XCTAssertEqual(
            prompts.first?.title,
            String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?")
        )
        XCTAssertEqual(prompts.first?.message, expectedMessage)
        XCTAssertEqual(prompts.first?.acceptCmdD, false)
        XCTAssertEqual(manager.tabs.map(\.title), ["Alpha", "Beta", "Gamma"])
    }
}


@MainActor
final class TabManagerCloseCurrentPanelTests: XCTestCase {
    func testRuntimeCloseSkipsConfirmationWhenShellReportsPromptIdle() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected selected workspace and focused terminal panel")
            return
        }

        terminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(true)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)

        var promptCount = 0
        manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return false
        }

        manager.closeRuntimeSurfaceWithConfirmation(tabId: workspace.id, surfaceId: panelId)
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(promptCount, 0, "Runtime closes should honor prompt-idle shell state")
        XCTAssertNil(workspace.panels[panelId], "Expected the original panel to close")
        XCTAssertEqual(workspace.panels.count, 1, "Expected a replacement surface after closing the last panel")
    }

    func testRuntimeClosePromptsWhenShellReportsRunningCommand() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected selected workspace and focused terminal panel")
            return
        }

        terminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(false)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)

        var promptCount = 0
        manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return false
        }

        manager.closeRuntimeSurfaceWithConfirmation(tabId: workspace.id, surfaceId: panelId)

        XCTAssertEqual(promptCount, 1, "Running commands should still require confirmation")
        XCTAssertNotNil(workspace.panels[panelId], "Prompt rejection should keep the original panel open")
    }

    func testCloseCurrentPanelClosesWorkspaceWhenItOwnsTheLastSurface() {
        let manager = TabManager()
        let firstWorkspace = manager.tabs[0]
        let secondWorkspace = manager.addWorkspace()
        manager.selectWorkspace(secondWorkspace)

        guard let secondPanelId = secondWorkspace.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
        XCTAssertEqual(secondWorkspace.panels.count, 1)

        manager.closeCurrentPanelWithConfirmation()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id])
        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertNil(secondWorkspace.panels[secondPanelId])
        XCTAssertTrue(secondWorkspace.panels.isEmpty)
    }

    func testCloseCurrentPanelPromptsBeforeClosingPinnedWorkspaceLastSurface() {
        let manager = TabManager()
        _ = manager.tabs[0]
        let pinnedWorkspace = manager.addWorkspace()
        manager.setPinned(pinnedWorkspace, pinned: true)
        manager.selectWorkspace(pinnedWorkspace)

        guard let pinnedPanelId = pinnedWorkspace.focusedPanelId else {
            XCTFail("Expected focused panel in pinned workspace")
            return
        }

        XCTAssertEqual(manager.selectedTabId, pinnedWorkspace.id)
        XCTAssertEqual(pinnedWorkspace.panels.count, 1)

        var prompts: [(title: String, message: String, acceptCmdD: Bool)] = []
        manager.confirmCloseHandler = { title, message, acceptCmdD in
            prompts.append((title, message, acceptCmdD))
            return false
        }

        manager.closeCurrentPanelWithConfirmation()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(
            prompts.first?.title,
            String(localized: "dialog.closePinnedWorkspace.title", defaultValue: "Close pinned workspace?")
        )
        XCTAssertEqual(
            prompts.first?.message,
            String(
                localized: "dialog.closePinnedWorkspace.message",
                defaultValue: "This workspace is pinned. Closing it will close the workspace and all of its panels."
            )
        )
        XCTAssertEqual(prompts.first?.acceptCmdD, false)
        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertTrue(manager.tabs.contains(where: { $0.id == pinnedWorkspace.id }))
        XCTAssertEqual(manager.selectedTabId, pinnedWorkspace.id)
        XCTAssertNotNil(pinnedWorkspace.panels[pinnedPanelId])
        XCTAssertEqual(pinnedWorkspace.panels.count, 1)
    }

    func testCloseCurrentPanelClosesPinnedWorkspaceAfterConfirmation() {
        let manager = TabManager()
        let firstWorkspace = manager.tabs[0]
        let pinnedWorkspace = manager.addWorkspace()
        manager.setPinned(pinnedWorkspace, pinned: true)
        manager.selectWorkspace(pinnedWorkspace)

        guard let pinnedPanelId = pinnedWorkspace.focusedPanelId else {
            XCTFail("Expected focused panel in pinned workspace")
            return
        }

        manager.confirmCloseHandler = { _, _, _ in true }

        manager.closeCurrentPanelWithConfirmation()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id])
        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertNil(pinnedWorkspace.panels[pinnedPanelId])
        XCTAssertTrue(pinnedWorkspace.panels.isEmpty)
    }

    func testCloseCurrentPanelKeepsWorkspaceOpenWhenKeepWorkspaceOpenPreferenceIsEnabled() {
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: lastSurfaceCloseShortcutDefaultsKey)
        defaults.set(false, forKey: lastSurfaceCloseShortcutDefaultsKey)
        defer {
            if let originalSetting {
                defaults.set(originalSetting, forKey: lastSurfaceCloseShortcutDefaultsKey)
            } else {
                defaults.removeObject(forKey: lastSurfaceCloseShortcutDefaultsKey)
            }
        }

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace and focused panel")
            return
        }

        let initialWorkspaceId = workspace.id

        manager.closeCurrentPanelWithConfirmation()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.selectedTabId, initialWorkspaceId)
        XCTAssertEqual(manager.tabs.first?.id, initialWorkspaceId)
        XCTAssertNil(workspace.panels[initialPanelId])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertNotEqual(workspace.focusedPanelId, initialPanelId)
    }

    func testClosePanelButtonClosesWorkspaceWhenItOwnsTheLastSurface() {
        let manager = TabManager()
        let firstWorkspace = manager.tabs[0]
        let secondWorkspace = manager.addWorkspace()
        manager.selectWorkspace(secondWorkspace)

        guard let secondPanelId = secondWorkspace.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
        XCTAssertEqual(secondWorkspace.panels.count, 1)

        guard let secondSurfaceId = secondWorkspace.surfaceIdFromPanelId(secondPanelId) else {
            XCTFail("Expected bonsplit surface ID for focused panel")
            return
        }

        secondWorkspace.markExplicitClose(surfaceId: secondSurfaceId)
        XCTAssertFalse(secondWorkspace.closePanel(secondPanelId))
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id])
        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertNil(secondWorkspace.panels[secondPanelId])
        XCTAssertTrue(secondWorkspace.panels.isEmpty)
    }

    func testClosePanelButtonStillClosesWorkspaceWhenKeepWorkspaceOpenPreferenceIsEnabled() {
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: lastSurfaceCloseShortcutDefaultsKey)
        defaults.set(false, forKey: lastSurfaceCloseShortcutDefaultsKey)
        defer {
            if let originalSetting {
                defaults.set(originalSetting, forKey: lastSurfaceCloseShortcutDefaultsKey)
            } else {
                defaults.removeObject(forKey: lastSurfaceCloseShortcutDefaultsKey)
            }
        }

        let manager = TabManager()
        let firstWorkspace = manager.tabs[0]
        let secondWorkspace = manager.addWorkspace()
        manager.selectWorkspace(secondWorkspace)

        guard let secondPanelId = secondWorkspace.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        guard let secondSurfaceId = secondWorkspace.surfaceIdFromPanelId(secondPanelId) else {
            XCTFail("Expected bonsplit surface ID for focused panel")
            return
        }

        secondWorkspace.markExplicitClose(surfaceId: secondSurfaceId)
        XCTAssertFalse(secondWorkspace.closePanel(secondPanelId))
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id])
        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertNil(secondWorkspace.panels[secondPanelId])
        XCTAssertTrue(secondWorkspace.panels.isEmpty)
    }

    func testGenericClosePanelKeepsWorkspaceOpenWithoutExplicitCloseMarker() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace and focused panel")
            return
        }

        let initialWorkspaceId = workspace.id
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(workspace.panels.count, 1)

        XCTAssertTrue(workspace.closePanel(initialPanelId))
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.selectedTabId, initialWorkspaceId)
        XCTAssertEqual(manager.tabs.first?.id, initialWorkspaceId)
        XCTAssertNil(workspace.panels[initialPanelId])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertNotEqual(workspace.focusedPanelId, initialPanelId)
    }

    func testCloseCurrentPanelIgnoresStaleSurfaceId() {
        let manager = TabManager()
        let firstWorkspace = manager.tabs[0]
        let secondWorkspace = manager.addWorkspace()

        manager.closePanelWithConfirmation(tabId: secondWorkspace.id, surfaceId: UUID())

        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id, secondWorkspace.id])
    }

    func testCloseCurrentPanelClearsNotificationsForClosedSurface() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        guard let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace and focused panel")
            return
        }

        store.addNotification(
            tabId: workspace.id,
            surfaceId: initialPanelId,
            title: "Unread",
            subtitle: "",
            body: ""
        )
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: initialPanelId))

        manager.closeCurrentPanelWithConfirmation()
        drainMainQueue()
        drainMainQueue()

        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: initialPanelId))
    }
}


@MainActor
final class TabManagerNotificationFocusTests: XCTestCase {
    func testFocusTabFromNotificationClearsSplitZoomBeforeFocusingTargetPanel() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split setup to succeed")
            return
        }

        workspace.focusPanel(leftPanelId)
        XCTAssertTrue(workspace.toggleSplitZoom(panelId: leftPanelId), "Expected split zoom to enable")
        XCTAssertTrue(workspace.bonsplitController.isSplitZoomed, "Expected workspace to start zoomed")

        XCTAssertTrue(manager.focusTabFromNotification(workspace.id, surfaceId: rightPanel.id))
        drainMainQueue()
        drainMainQueue()

        XCTAssertFalse(
            workspace.bonsplitController.isSplitZoomed,
            "Expected notification focus to exit split zoom so the target pane becomes visible"
        )
        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id, "Expected notification target panel to be focused")
    }

    func testFocusTabFromNotificationReturnsFalseForMissingPanel() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        XCTAssertFalse(manager.focusTabFromNotification(workspace.id, surfaceId: UUID()))
    }

    func testFocusTabFromNotificationDismissesUnreadWithDismissFlash() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let defaults = UserDefaults.standard

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        let originalExperimentEnabled = defaults.object(forKey: TmuxOverlayExperimentSettings.enabledKey)
        let originalExperimentTarget = defaults.object(forKey: TmuxOverlayExperimentSettings.targetKey)

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true
        defaults.set(true, forKey: TmuxOverlayExperimentSettings.enabledKey)
        defaults.set(TmuxOverlayExperimentTarget.bonsplitPane.rawValue, forKey: TmuxOverlayExperimentSettings.targetKey)

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            if let originalExperimentEnabled {
                defaults.set(originalExperimentEnabled, forKey: TmuxOverlayExperimentSettings.enabledKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.enabledKey)
            }
            if let originalExperimentTarget {
                defaults.set(originalExperimentTarget, forKey: TmuxOverlayExperimentSettings.targetKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.targetKey)
            }
        }

        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        workspace.focusPanel(leftPanelId)
        store.addNotification(
            tabId: workspace.id,
            surfaceId: rightPanel.id,
            title: "Unread",
            subtitle: "",
            body: "Right pane should dismiss attention when focused from a notification"
        )

        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: rightPanel.id))
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: rightPanel.id))
        XCTAssertEqual(workspace.tmuxWorkspaceFlashToken, 0)

        XCTAssertTrue(manager.focusTabFromNotification(workspace.id, surfaceId: rightPanel.id))

        let expectation = XCTestExpectation(description: "notification focus flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: rightPanel.id))
        XCTAssertFalse(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: rightPanel.id))
        XCTAssertEqual(workspace.tmuxWorkspaceFlashToken, 1)
        XCTAssertEqual(workspace.tmuxWorkspaceFlashPanelId, rightPanel.id)
        XCTAssertEqual(workspace.tmuxWorkspaceFlashReason, .notificationDismiss)
    }
}


@MainActor
final class TabManagerPendingUnfocusPolicyTests: XCTestCase {
    func testDoesNotUnfocusWhenPendingTabIsCurrentlySelected() {
        let tabId = UUID()

        XCTAssertFalse(
            TabManager.shouldUnfocusPendingWorkspace(
                pendingTabId: tabId,
                selectedTabId: tabId
            )
        )
    }

    func testUnfocusesWhenPendingTabIsNotSelected() {
        XCTAssertTrue(
            TabManager.shouldUnfocusPendingWorkspace(
                pendingTabId: UUID(),
                selectedTabId: UUID()
            )
        )
        XCTAssertTrue(
            TabManager.shouldUnfocusPendingWorkspace(
                pendingTabId: UUID(),
                selectedTabId: nil
            )
        )
    }
}


@MainActor
final class TabManagerSurfaceCreationTests: XCTestCase {
    func testNewSurfaceFocusesCreatedSurface() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected a selected workspace")
            return
        }

        let beforePanels = Set(workspace.panels.keys)
        manager.newSurface()
        let afterPanels = Set(workspace.panels.keys)

        let createdPanels = afterPanels.subtracting(beforePanels)
        XCTAssertEqual(createdPanels.count, 1, "Expected one new surface for Cmd+T path")
        guard let createdPanelId = createdPanels.first else { return }

        XCTAssertEqual(
            workspace.focusedPanelId,
            createdPanelId,
            "Expected newly created surface to be focused"
        )
    }

    func testOpenBrowserInsertAtEndPlacesNewBrowserAtPaneEnd() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected focused workspace and pane")
            return
        }

        // Add one extra surface so we verify append-to-end rather than first insert behavior.
        _ = workspace.newTerminalSurface(inPane: paneId, focus: false)

        guard let browserPanelId = manager.openBrowser(insertAtEnd: true) else {
            XCTFail("Expected browser panel to be created")
            return
        }

        let tabs = workspace.bonsplitController.tabs(inPane: paneId)
        guard let lastSurfaceId = tabs.last?.id else {
            XCTFail("Expected at least one surface in pane")
            return
        }

        XCTAssertEqual(
            workspace.panelIdFromSurfaceId(lastSurfaceId),
            browserPanelId,
            "Expected Cmd+Shift+B/Cmd+L open path to append browser surface at end"
        )
        XCTAssertEqual(workspace.focusedPanelId, browserPanelId, "Expected opened browser surface to be focused")
    }

    func testOpenBrowserInWorkspaceSplitRightSelectsTargetWorkspaceAndCreatesSplit() {
        let manager = TabManager()
        guard let initialWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected initial selected workspace")
            return
        }
        guard let url = URL(string: "https://example.com/pull/123") else {
            XCTFail("Expected test URL to be valid")
            return
        }

        let targetWorkspace = manager.addWorkspace(select: false)
        manager.selectWorkspace(initialWorkspace)
        let initialPaneCount = targetWorkspace.bonsplitController.allPaneIds.count
        let initialPanelCount = targetWorkspace.panels.count

        guard let browserPanelId = manager.openBrowser(
            inWorkspace: targetWorkspace.id,
            url: url,
            preferSplitRight: true,
            insertAtEnd: true
        ) else {
            XCTFail("Expected browser panel to be created in target workspace")
            return
        }

        XCTAssertEqual(manager.selectedTabId, targetWorkspace.id, "Expected target workspace to become selected")
        XCTAssertEqual(
            targetWorkspace.bonsplitController.allPaneIds.count,
            initialPaneCount + 1,
            "Expected split-right browser open to create a new pane"
        )
        XCTAssertEqual(
            targetWorkspace.panels.count,
            initialPanelCount + 1,
            "Expected browser panel count to increase by one"
        )
        XCTAssertEqual(
            targetWorkspace.focusedPanelId,
            browserPanelId,
            "Expected created browser panel to be focused in target workspace"
        )
        XCTAssertTrue(
            targetWorkspace.panels[browserPanelId] is BrowserPanel,
            "Expected created panel to be a browser panel"
        )
    }

    func testOpenBrowserInWorkspaceSplitRightReusesTopRightPaneWhenAlreadySplit() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let topRightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal),
              workspace.newTerminalSplit(from: topRightPanel.id, orientation: .vertical) != nil,
              let topRightPaneId = workspace.paneId(forPanelId: topRightPanel.id),
              let url = URL(string: "https://example.com/pull/456") else {
            XCTFail("Expected split setup to succeed")
            return
        }

        let initialPaneCount = workspace.bonsplitController.allPaneIds.count

        guard let browserPanelId = manager.openBrowser(
            inWorkspace: workspace.id,
            url: url,
            preferSplitRight: true,
            insertAtEnd: true
        ) else {
            XCTFail("Expected browser panel to be created")
            return
        }

        XCTAssertEqual(
            workspace.bonsplitController.allPaneIds.count,
            initialPaneCount,
            "Expected split-right browser open to reuse existing panes"
        )
        XCTAssertEqual(
            workspace.paneId(forPanelId: browserPanelId),
            topRightPaneId,
            "Expected browser to open in the top-right pane when multiple splits already exist"
        )

        let targetPaneTabs = workspace.bonsplitController.tabs(inPane: topRightPaneId)
        guard let lastSurfaceId = targetPaneTabs.last?.id else {
            XCTFail("Expected top-right pane to contain tabs")
            return
        }
        XCTAssertEqual(
            workspace.panelIdFromSurfaceId(lastSurfaceId),
            browserPanelId,
            "Expected browser surface to be appended at end in the reused top-right pane"
        )
    }
}


@MainActor
final class TabManagerEqualizeSplitsTests: XCTestCase {
    func testEqualizeSplitsSetsEverySplitDividerToHalf() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal),
              workspace.newTerminalSplit(from: rightPanel.id, orientation: .vertical) != nil else {
            XCTFail("Expected nested split setup to succeed")
            return
        }

        let initialSplits = splitNodes(in: workspace.bonsplitController.treeSnapshot())
        XCTAssertGreaterThanOrEqual(initialSplits.count, 2, "Expected at least two split nodes in nested layout")

        for (index, split) in initialSplits.enumerated() {
            guard let splitId = UUID(uuidString: split.id) else {
                XCTFail("Expected split ID to be a UUID")
                return
            }
            let targetPosition: CGFloat = index.isMultiple(of: 2) ? 0.2 : 0.8
            XCTAssertTrue(
                workspace.bonsplitController.setDividerPosition(targetPosition, forSplit: splitId),
                "Expected to seed divider position for split \(splitId)"
            )
        }

        XCTAssertTrue(manager.equalizeSplits(tabId: workspace.id), "Expected equalize splits command to succeed")

        let equalizedSplits = splitNodes(in: workspace.bonsplitController.treeSnapshot())
        XCTAssertEqual(equalizedSplits.count, initialSplits.count)
        for split in equalizedSplits {
            XCTAssertEqual(split.dividerPosition, 0.5, accuracy: 0.000_1)
        }
    }

    private func splitNodes(in node: ExternalTreeNode) -> [ExternalSplitNode] {
        switch node {
        case .pane:
            return []
        case .split(let split):
            return [split] + splitNodes(in: split.first) + splitNodes(in: split.second)
        }
    }
}


@MainActor
final class TabManagerWorkspaceConfigInheritanceSourceTests: XCTestCase {
    func testUsesFocusedTerminalWhenTerminalIsFocused() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused terminal")
            return
        }

        let sourcePanel = manager.terminalPanelForWorkspaceConfigInheritanceSource()
        XCTAssertEqual(sourcePanel?.id, terminalPanelId)
    }

    func testFallsBackToTerminalWhenBrowserIsFocused() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: terminalPanelId),
              let browserPanel = workspace.newBrowserSurface(inPane: paneId, focus: true) else {
            XCTFail("Expected selected workspace setup to succeed")
            return
        }

        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)

        let sourcePanel = manager.terminalPanelForWorkspaceConfigInheritanceSource()
        XCTAssertEqual(
            sourcePanel?.id,
            terminalPanelId,
            "Expected new workspace inheritance source to resolve to the pane terminal when browser is focused"
        )
    }

    func testPrefersLastFocusedTerminalAcrossPanesWhenBrowserIsFocused() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftTerminalPanelId = workspace.focusedPanelId,
              let rightTerminalPanel = workspace.newTerminalSplit(from: leftTerminalPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightTerminalPanel.id) else {
            XCTFail("Expected split setup to succeed")
            return
        }

        workspace.focusPanel(leftTerminalPanelId)
        _ = workspace.newBrowserSurface(inPane: rightPaneId, focus: true)
        XCTAssertNotEqual(workspace.focusedPanelId, leftTerminalPanelId)

        let sourcePanel = manager.terminalPanelForWorkspaceConfigInheritanceSource()
        XCTAssertEqual(
            sourcePanel?.id,
            leftTerminalPanelId,
            "Expected workspace inheritance source to use last focused terminal across panes"
        )
    }
}


@MainActor
final class TabManagerFocusedNotificationIndicatorTests: XCTestCase {
    func testFocusPanelDismissesUnreadNotificationWithDismissFlash() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let defaults = UserDefaults.standard

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        let originalExperimentEnabled = defaults.object(forKey: TmuxOverlayExperimentSettings.enabledKey)
        let originalExperimentTarget = defaults.object(forKey: TmuxOverlayExperimentSettings.targetKey)

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true
        defaults.set(true, forKey: TmuxOverlayExperimentSettings.enabledKey)
        defaults.set(TmuxOverlayExperimentTarget.bonsplitPane.rawValue, forKey: TmuxOverlayExperimentSettings.targetKey)

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            if let originalExperimentEnabled {
                defaults.set(originalExperimentEnabled, forKey: TmuxOverlayExperimentSettings.enabledKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.enabledKey)
            }
            if let originalExperimentTarget {
                defaults.set(originalExperimentTarget, forKey: TmuxOverlayExperimentSettings.targetKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.targetKey)
            }
        }

        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        store.addNotification(
            tabId: workspace.id,
            surfaceId: leftPanelId,
            title: "Unread",
            subtitle: "",
            body: "Left pane should dismiss attention when focused"
        )

        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: leftPanelId))
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: leftPanelId))
        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)
        XCTAssertEqual(workspace.tmuxWorkspaceFlashToken, 0)

        workspace.focusPanel(leftPanelId)

        XCTAssertEqual(workspace.focusedPanelId, leftPanelId)
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: leftPanelId))
        XCTAssertFalse(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: leftPanelId))
        XCTAssertEqual(workspace.tmuxWorkspaceFlashToken, 1)
        XCTAssertEqual(workspace.tmuxWorkspaceFlashPanelId, leftPanelId)
        XCTAssertEqual(workspace.tmuxWorkspaceFlashReason, .notificationDismiss)
    }

    func testDismissNotificationOnDirectInteractionClearsFocusedNotificationIndicator() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))

        XCTAssertTrue(
            manager.dismissNotificationOnDirectInteraction(tabId: workspace.id, surfaceId: panelId)
        )
        XCTAssertFalse(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))
    }

    func testDismissNotificationOnDirectInteractionTriggersDismissFlashForFocusedIndicatorOnly() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let defaults = UserDefaults.standard

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        let originalExperimentEnabled = defaults.object(forKey: TmuxOverlayExperimentSettings.enabledKey)
        let originalExperimentTarget = defaults.object(forKey: TmuxOverlayExperimentSettings.targetKey)

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true
        defaults.set(true, forKey: TmuxOverlayExperimentSettings.enabledKey)
        defaults.set(TmuxOverlayExperimentTarget.bonsplitPane.rawValue, forKey: TmuxOverlayExperimentSettings.targetKey)

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            if let originalExperimentEnabled {
                defaults.set(originalExperimentEnabled, forKey: TmuxOverlayExperimentSettings.enabledKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.enabledKey)
            }
            if let originalExperimentTarget {
                defaults.set(originalExperimentTarget, forKey: TmuxOverlayExperimentSettings.targetKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.targetKey)
            }
        }

        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelId))
        XCTAssertEqual(workspace.tmuxWorkspaceFlashToken, 0)

        XCTAssertTrue(
            manager.dismissNotificationOnDirectInteraction(tabId: workspace.id, surfaceId: panelId)
        )

        XCTAssertFalse(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))
        XCTAssertEqual(
            workspace.tmuxWorkspaceFlashToken,
            1,
            "Expected dismissing a focused-read indicator to emit a dismiss flash even when unread is already cleared"
        )
        XCTAssertEqual(workspace.tmuxWorkspaceFlashPanelId, panelId)
        XCTAssertEqual(workspace.tmuxWorkspaceFlashReason, .notificationDismiss)
    }
}

@MainActor
final class TabManagerReopenClosedBrowserFocusTests: XCTestCase {
    func testReopenFromDifferentWorkspaceFocusesReopenedBrowser() {
        let manager = TabManager()
        guard let workspace1 = manager.selectedWorkspace,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/ws-switch")) else {
            XCTFail("Expected initial workspace and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace1.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let workspace2 = manager.addWorkspace()
        XCTAssertEqual(manager.selectedTabId, workspace2.id)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace1.id)
        XCTAssertTrue(isFocusedPanelBrowser(in: workspace1))
    }

    func testReopenFallsBackToCurrentWorkspaceAndFocusesBrowserWhenOriginalWorkspaceDeleted() {
        let manager = TabManager()
        guard let originalWorkspace = manager.selectedWorkspace,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/deleted-ws")) else {
            XCTFail("Expected initial workspace and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(originalWorkspace.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let currentWorkspace = manager.addWorkspace()
        manager.closeWorkspace(originalWorkspace)

        XCTAssertEqual(manager.selectedTabId, currentWorkspace.id)
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == originalWorkspace.id }))

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, currentWorkspace.id)
        XCTAssertTrue(isFocusedPanelBrowser(in: currentWorkspace))
    }

    func testReopenCollapsedSplitFromDifferentWorkspaceFocusesBrowser() {
        let manager = TabManager()
        guard let workspace1 = manager.selectedWorkspace,
              let sourcePanelId = workspace1.focusedPanelId,
              let splitBrowserId = manager.newBrowserSplit(
                tabId: workspace1.id,
                fromPanelId: sourcePanelId,
                orientation: .horizontal,
                insertFirst: false,
                url: URL(string: "https://example.com/collapsed-split")
              ) else {
            XCTFail("Expected to create browser split")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace1.closePanel(splitBrowserId, force: true))
        drainMainQueue()

        let workspace2 = manager.addWorkspace()
        XCTAssertEqual(manager.selectedTabId, workspace2.id)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace1.id)
        XCTAssertTrue(isFocusedPanelBrowser(in: workspace1))
    }

    func testReopenFromDifferentWorkspaceWinsAgainstSingleDeferredStaleFocus() {
        let manager = TabManager()
        guard let workspace1 = manager.selectedWorkspace,
              let preReopenPanelId = workspace1.focusedPanelId,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/stale-focus-cross-ws")) else {
            XCTFail("Expected initial workspace state and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace1.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let panelIdsBeforeReopen = Set(workspace1.panels.keys)
        let workspace2 = manager.addWorkspace()
        XCTAssertEqual(manager.selectedTabId, workspace2.id)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        guard let reopenedPanelId = singleNewPanelId(in: workspace1, comparedTo: panelIdsBeforeReopen) else {
            XCTFail("Expected reopened browser panel ID")
            return
        }

        // Simulate one delayed stale focus callback from the panel that was focused before reopen.
        DispatchQueue.main.async {
            workspace1.focusPanel(preReopenPanelId)
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace1.id)
        XCTAssertEqual(workspace1.focusedPanelId, reopenedPanelId)
        XCTAssertTrue(workspace1.panels[reopenedPanelId] is BrowserPanel)
    }

    func testReopenInSameWorkspaceWinsAgainstSingleDeferredStaleFocus() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let preReopenPanelId = workspace.focusedPanelId,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/stale-focus-same-ws")) else {
            XCTFail("Expected initial workspace state and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let panelIdsBeforeReopen = Set(workspace.panels.keys)
        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        guard let reopenedPanelId = singleNewPanelId(in: workspace, comparedTo: panelIdsBeforeReopen) else {
            XCTFail("Expected reopened browser panel ID")
            return
        }

        // Simulate one delayed stale focus callback from the panel that was focused before reopen.
        DispatchQueue.main.async {
            workspace.focusPanel(preReopenPanelId)
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace.id)
        XCTAssertEqual(workspace.focusedPanelId, reopenedPanelId)
        XCTAssertTrue(workspace.panels[reopenedPanelId] is BrowserPanel)
    }

    private func isFocusedPanelBrowser(in workspace: Workspace) -> Bool {
        guard let focusedPanelId = workspace.focusedPanelId else { return false }
        return workspace.panels[focusedPanelId] is BrowserPanel
    }

    private func singleNewPanelId(in workspace: Workspace, comparedTo previousPanelIds: Set<UUID>) -> UUID? {
        let newPanelIds = Set(workspace.panels.keys).subtracting(previousPanelIds)
        guard newPanelIds.count == 1 else { return nil }
        return newPanelIds.first
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "drain main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }
}
