import XCTest
import AppKit
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CmuxWebViewKeyEquivalentTests: XCTestCase {
    private final class ActionSpy: NSObject {
        private(set) var invoked: Bool = false

        @objc func didInvoke(_ sender: Any?) {
            invoked = true
        }
    }

    func testCmdNRoutesToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "n", modifiers: [.command])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "n", modifiers: [.command], keyCode: 45) // kVK_ANSI_N
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertTrue(spy.invoked)
    }

    func testCmdWRoutesToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "w", modifiers: [.command])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "w", modifiers: [.command], keyCode: 13) // kVK_ANSI_W
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertTrue(spy.invoked)
    }

    func testCmdRRoutesToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "r", modifiers: [.command])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "r", modifiers: [.command], keyCode: 15) // kVK_ANSI_R
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertTrue(spy.invoked)
    }

    private func installMenu(spy: ActionSpy, key: String, modifiers: NSEvent.ModifierFlags) {
        let mainMenu = NSMenu()

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")

        let item = NSMenuItem(title: "Test Item", action: #selector(ActionSpy.didInvoke(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = spy
        fileMenu.addItem(item)

        mainMenu.addItem(fileItem)
        mainMenu.setSubmenu(fileMenu, for: fileItem)

        // Ensure NSApp exists and has a menu for performKeyEquivalent to consult.
        _ = NSApplication.shared
        NSApp.mainMenu = mainMenu
    }

    private func makeKeyDownEvent(key: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}

final class WorkspaceShortcutMapperTests: XCTestCase {
    func testCommandNineMapsToLastWorkspaceIndex() {
        XCTAssertEqual(WorkspaceShortcutMapper.workspaceIndex(forCommandDigit: 9, workspaceCount: 1), 0)
        XCTAssertEqual(WorkspaceShortcutMapper.workspaceIndex(forCommandDigit: 9, workspaceCount: 4), 3)
        XCTAssertEqual(WorkspaceShortcutMapper.workspaceIndex(forCommandDigit: 9, workspaceCount: 12), 11)
    }

    func testCommandDigitBadgesUseNineForLastWorkspaceWhenNeeded() {
        XCTAssertEqual(WorkspaceShortcutMapper.commandDigitForWorkspace(at: 0, workspaceCount: 12), 1)
        XCTAssertEqual(WorkspaceShortcutMapper.commandDigitForWorkspace(at: 7, workspaceCount: 12), 8)
        XCTAssertEqual(WorkspaceShortcutMapper.commandDigitForWorkspace(at: 11, workspaceCount: 12), 9)
        XCTAssertNil(WorkspaceShortcutMapper.commandDigitForWorkspace(at: 8, workspaceCount: 12))
    }
}

final class SidebarCommandHintPolicyTests: XCTestCase {
    func testCommandHintRequiresCommandOnlyModifier() {
        XCTAssertTrue(SidebarCommandHintPolicy.shouldShowHints(for: [.command]))
        XCTAssertFalse(SidebarCommandHintPolicy.shouldShowHints(for: []))
        XCTAssertFalse(SidebarCommandHintPolicy.shouldShowHints(for: [.command, .shift]))
        XCTAssertFalse(SidebarCommandHintPolicy.shouldShowHints(for: [.command, .option]))
        XCTAssertFalse(SidebarCommandHintPolicy.shouldShowHints(for: [.command, .control]))
    }

    func testCommandHintUsesIntentionalHoldDelay() {
        XCTAssertGreaterThanOrEqual(SidebarCommandHintPolicy.intentionalHoldDelay, 0.25)
    }
}

final class ShortcutHintDebugSettingsTests: XCTestCase {
    func testClampKeepsValuesWithinSupportedRange() {
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(0.0), 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(4.0), 4.0)
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(-100.0), ShortcutHintDebugSettings.offsetRange.lowerBound)
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(100.0), ShortcutHintDebugSettings.offsetRange.upperBound)
    }

    func testDefaultOffsetsMatchCurrentBadgePlacements() {
        XCTAssertEqual(ShortcutHintDebugSettings.defaultSidebarHintX, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultSidebarHintY, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultTitlebarHintX, 4.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultTitlebarHintY, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultPaneHintX, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultPaneHintY, 0.0)
        XCTAssertFalse(ShortcutHintDebugSettings.defaultAlwaysShowHints)
    }
}

final class ShortcutHintLanePlannerTests: XCTestCase {
    func testAssignLanesKeepsSeparatedIntervalsOnSingleLane() {
        let intervals: [ClosedRange<CGFloat>] = [0...20, 28...40, 48...64]
        XCTAssertEqual(ShortcutHintLanePlanner.assignLanes(for: intervals, minSpacing: 4), [0, 0, 0])
    }

    func testAssignLanesStacksOverlappingIntervalsIntoAdditionalLanes() {
        let intervals: [ClosedRange<CGFloat>] = [0...20, 18...34, 22...38, 40...56]
        XCTAssertEqual(ShortcutHintLanePlanner.assignLanes(for: intervals, minSpacing: 4), [0, 1, 2, 0])
    }
}

final class ShortcutHintHorizontalPlannerTests: XCTestCase {
    func testAssignRightEdgesResolvesOverlapWithMinimumSpacing() {
        let intervals: [ClosedRange<CGFloat>] = [0...20, 18...34, 30...46]
        let rightEdges = ShortcutHintHorizontalPlanner.assignRightEdges(for: intervals, minSpacing: 6)

        XCTAssertEqual(rightEdges.count, intervals.count)

        let adjustedIntervals = zip(intervals, rightEdges).map { interval, rightEdge in
            let width = interval.upperBound - interval.lowerBound
            return (rightEdge - width)...rightEdge
        }

        XCTAssertGreaterThanOrEqual(adjustedIntervals[1].lowerBound - adjustedIntervals[0].upperBound, 6)
        XCTAssertGreaterThanOrEqual(adjustedIntervals[2].lowerBound - adjustedIntervals[1].upperBound, 6)
    }

    func testAssignRightEdgesKeepsAlreadySeparatedIntervalsInPlace() {
        let intervals: [ClosedRange<CGFloat>] = [0...12, 20...32, 40...52]
        let rightEdges = ShortcutHintHorizontalPlanner.assignRightEdges(for: intervals, minSpacing: 4)
        XCTAssertEqual(rightEdges, [12, 32, 52])
    }
}

final class WorkspacePlacementSettingsTests: XCTestCase {
    func testCurrentPlacementDefaultsToAfterCurrentWhenUnset() {
        let suiteName = "WorkspacePlacementSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(WorkspacePlacementSettings.current(defaults: defaults), .afterCurrent)
    }

    func testCurrentPlacementReadsStoredValidValueAndFallsBackForInvalid() {
        let suiteName = "WorkspacePlacementSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(NewWorkspacePlacement.top.rawValue, forKey: WorkspacePlacementSettings.placementKey)
        XCTAssertEqual(WorkspacePlacementSettings.current(defaults: defaults), .top)

        defaults.set("nope", forKey: WorkspacePlacementSettings.placementKey)
        XCTAssertEqual(WorkspacePlacementSettings.current(defaults: defaults), .afterCurrent)
    }

    func testInsertionIndexTopInsertsBeforeUnpinned() {
        let index = WorkspacePlacementSettings.insertionIndex(
            placement: .top,
            selectedIndex: 4,
            selectedIsPinned: false,
            pinnedCount: 2,
            totalCount: 7
        )
        XCTAssertEqual(index, 2)
    }

    func testInsertionIndexAfterCurrentHandlesPinnedAndUnpinnedSelection() {
        let afterUnpinned = WorkspacePlacementSettings.insertionIndex(
            placement: .afterCurrent,
            selectedIndex: 3,
            selectedIsPinned: false,
            pinnedCount: 2,
            totalCount: 6
        )
        XCTAssertEqual(afterUnpinned, 4)

        let afterPinned = WorkspacePlacementSettings.insertionIndex(
            placement: .afterCurrent,
            selectedIndex: 0,
            selectedIsPinned: true,
            pinnedCount: 2,
            totalCount: 6
        )
        XCTAssertEqual(afterPinned, 2)
    }

    func testInsertionIndexEndAndNoSelectionAppend() {
        let endIndex = WorkspacePlacementSettings.insertionIndex(
            placement: .end,
            selectedIndex: 1,
            selectedIsPinned: false,
            pinnedCount: 1,
            totalCount: 5
        )
        XCTAssertEqual(endIndex, 5)

        let noSelectionIndex = WorkspacePlacementSettings.insertionIndex(
            placement: .afterCurrent,
            selectedIndex: nil,
            selectedIsPinned: false,
            pinnedCount: 0,
            totalCount: 5
        )
        XCTAssertEqual(noSelectionIndex, 5)
    }
}

final class UpdateChannelSettingsTests: XCTestCase {
    func testDefaultNightlyPreferenceIsDisabled() {
        XCTAssertFalse(UpdateChannelSettings.defaultIncludeNightlyBuilds)
    }

    func testResolvedFeedFallsBackToStableWhenInfoFeedMissing() {
        let suiteName = "UpdateChannelSettingsTests.MissingInfo.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let resolved = UpdateChannelSettings.resolvedFeedURLString(infoFeedURL: nil, defaults: defaults)
        XCTAssertEqual(resolved.url, UpdateChannelSettings.stableFeedURL)
        XCTAssertFalse(resolved.isNightly)
        XCTAssertTrue(resolved.usedFallback)
    }

    func testResolvedFeedUsesInfoFeedForStableChannel() {
        let suiteName = "UpdateChannelSettingsTests.InfoFeed.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let infoFeed = "https://example.com/custom/appcast.xml"
        let resolved = UpdateChannelSettings.resolvedFeedURLString(infoFeedURL: infoFeed, defaults: defaults)
        XCTAssertEqual(resolved.url, infoFeed)
        XCTAssertFalse(resolved.isNightly)
        XCTAssertFalse(resolved.usedFallback)
    }

    func testResolvedFeedUsesNightlyWhenPreferenceEnabled() {
        let suiteName = "UpdateChannelSettingsTests.Nightly.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: UpdateChannelSettings.includeNightlyBuildsKey)
        let resolved = UpdateChannelSettings.resolvedFeedURLString(
            infoFeedURL: "https://example.com/custom/appcast.xml",
            defaults: defaults
        )
        XCTAssertEqual(resolved.url, UpdateChannelSettings.nightlyFeedURL)
        XCTAssertTrue(resolved.isNightly)
        XCTAssertFalse(resolved.usedFallback)
    }
}

final class WorkspaceReorderTests: XCTestCase {
    @MainActor
    func testReorderWorkspaceMovesWorkspaceToRequestedIndex() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()

        manager.selectWorkspace(second)
        XCTAssertEqual(manager.selectedTabId, second.id)

        XCTAssertTrue(manager.reorderWorkspace(tabId: second.id, toIndex: 0))
        XCTAssertEqual(manager.tabs.map(\.id), [second.id, first.id, third.id])
        XCTAssertEqual(manager.selectedTabId, second.id)
    }

    @MainActor
    func testReorderWorkspaceClampsOutOfRangeTargetIndex() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()

        XCTAssertTrue(manager.reorderWorkspace(tabId: first.id, toIndex: 999))
        XCTAssertEqual(manager.tabs.map(\.id), [second.id, third.id, first.id])
    }

    @MainActor
    func testReorderWorkspaceReturnsFalseForUnknownWorkspace() {
        let manager = TabManager()
        XCTAssertFalse(manager.reorderWorkspace(tabId: UUID(), toIndex: 0))
    }
}

final class SidebarDropPlannerTests: XCTestCase {
    func testNoIndicatorForNoOpEdges() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: first,
                targetTabId: first,
                tabIds: tabIds
            )
        )
        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: third,
                targetTabId: nil,
                tabIds: tabIds
            )
        )
    }

    func testNoIndicatorWhenOnlyOneTabExists() {
        let only = UUID()
        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: only,
                targetTabId: nil,
                tabIds: [only]
            )
        )
        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: only,
                targetTabId: only,
                tabIds: [only]
            )
        )
    }

    func testIndicatorAppearsForRealMoveToEnd() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let indicator = SidebarDropPlanner.indicator(
            draggedTabId: second,
            targetTabId: nil,
            tabIds: tabIds
        )
        XCTAssertEqual(indicator?.tabId, nil)
        XCTAssertEqual(indicator?.edge, .bottom)
    }

    func testTargetIndexForMoveToEndFromMiddle() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let index = SidebarDropPlanner.targetIndex(
            draggedTabId: second,
            targetTabId: nil,
            indicator: SidebarDropIndicator(tabId: nil, edge: .bottom),
            tabIds: tabIds
        )
        XCTAssertEqual(index, 2)
    }

    func testNoIndicatorForSelfDropInMiddle() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: second,
                targetTabId: second,
                tabIds: tabIds
            )
        )
    }

    func testPointerEdgeTopCanSuppressNoOpWhenDraggingFirstOverSecond() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: first,
                targetTabId: second,
                tabIds: tabIds,
                pointerY: 2,
                targetHeight: 40
            )
        )
    }

    func testPointerEdgeBottomAllowsMoveWhenDraggingFirstOverSecond() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let indicator = SidebarDropPlanner.indicator(
            draggedTabId: first,
            targetTabId: second,
            tabIds: tabIds,
            pointerY: 38,
            targetHeight: 40
        )
        XCTAssertEqual(indicator?.tabId, third)
        XCTAssertEqual(indicator?.edge, .top)
        XCTAssertEqual(
            SidebarDropPlanner.targetIndex(
                draggedTabId: first,
                targetTabId: second,
                indicator: indicator,
                tabIds: tabIds
            ),
            1
        )
    }

    func testEquivalentBoundaryInputsResolveToSingleCanonicalIndicator() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let fromBottomOfFirst = SidebarDropPlanner.indicator(
            draggedTabId: third,
            targetTabId: first,
            tabIds: tabIds,
            pointerY: 38,
            targetHeight: 40
        )
        let fromTopOfSecond = SidebarDropPlanner.indicator(
            draggedTabId: third,
            targetTabId: second,
            tabIds: tabIds,
            pointerY: 2,
            targetHeight: 40
        )

        XCTAssertEqual(fromBottomOfFirst?.tabId, second)
        XCTAssertEqual(fromBottomOfFirst?.edge, .top)
        XCTAssertEqual(fromTopOfSecond?.tabId, second)
        XCTAssertEqual(fromTopOfSecond?.edge, .top)
    }

    func testPointerEdgeBottomSuppressesNoOpWhenDraggingLastOverSecond() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: third,
                targetTabId: second,
                tabIds: tabIds,
                pointerY: 38,
                targetHeight: 40
            )
        )
    }
}

final class SidebarDragAutoScrollPlannerTests: XCTestCase {
    func testAutoScrollPlanTriggersNearTopAndBottomOnly() {
        let topPlan = SidebarDragAutoScrollPlanner.plan(distanceToTop: 4, distanceToBottom: 96, edgeInset: 44, minStep: 2, maxStep: 12)
        XCTAssertEqual(topPlan?.direction, .up)
        XCTAssertNotNil(topPlan)

        let bottomPlan = SidebarDragAutoScrollPlanner.plan(distanceToTop: 96, distanceToBottom: 4, edgeInset: 44, minStep: 2, maxStep: 12)
        XCTAssertEqual(bottomPlan?.direction, .down)
        XCTAssertNotNil(bottomPlan)

        XCTAssertNil(
            SidebarDragAutoScrollPlanner.plan(distanceToTop: 60, distanceToBottom: 60, edgeInset: 44, minStep: 2, maxStep: 12)
        )
    }

    func testAutoScrollPlanSpeedsUpCloserToEdge() {
        let nearTop = SidebarDragAutoScrollPlanner.plan(distanceToTop: 1, distanceToBottom: 99, edgeInset: 44, minStep: 2, maxStep: 12)
        let midTop = SidebarDragAutoScrollPlanner.plan(distanceToTop: 22, distanceToBottom: 78, edgeInset: 44, minStep: 2, maxStep: 12)

        XCTAssertNotNil(nearTop)
        XCTAssertNotNil(midTop)
        XCTAssertGreaterThan(nearTop?.pointsPerTick ?? 0, midTop?.pointsPerTick ?? 0)
    }

    func testAutoScrollPlanStillTriggersWhenPointerIsPastEdge() {
        let aboveTop = SidebarDragAutoScrollPlanner.plan(distanceToTop: -500, distanceToBottom: 600, edgeInset: 44, minStep: 2, maxStep: 12)
        XCTAssertEqual(aboveTop?.direction, .up)
        XCTAssertEqual(aboveTop?.pointsPerTick, 12)

        let belowBottom = SidebarDragAutoScrollPlanner.plan(distanceToTop: 600, distanceToBottom: -500, edgeInset: 44, minStep: 2, maxStep: 12)
        XCTAssertEqual(belowBottom?.direction, .down)
        XCTAssertEqual(belowBottom?.pointsPerTick, 12)
    }
}

final class FinderServicePathResolverTests: XCTestCase {
    func testOrderedUniqueDirectoriesUsesParentForFilesAndDedupes() {
        let input: [URL] = [
            URL(fileURLWithPath: "/tmp/cmux-services/project", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmux-services/project/README.md", isDirectory: false),
            URL(fileURLWithPath: "/tmp/cmux-services/../cmux-services/project", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmux-services/other", isDirectory: true),
        ]

        let directories = FinderServicePathResolver.orderedUniqueDirectories(from: input)
        XCTAssertEqual(
            directories,
            [
                "/tmp/cmux-services/project",
                "/tmp/cmux-services/other",
            ]
        )
    }

    func testOrderedUniqueDirectoriesPreservesFirstSeenOrder() {
        let input: [URL] = [
            URL(fileURLWithPath: "/tmp/cmux-services/b", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmux-services/a/file.txt", isDirectory: false),
            URL(fileURLWithPath: "/tmp/cmux-services/a", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmux-services/b/file.txt", isDirectory: false),
        ]

        let directories = FinderServicePathResolver.orderedUniqueDirectories(from: input)
        XCTAssertEqual(
            directories,
            [
                "/tmp/cmux-services/b",
                "/tmp/cmux-services/a",
            ]
        )
    }
}

final class BrowserSearchEngineTests: XCTestCase {
    func testGoogleSearchURL() throws {
        let url = try XCTUnwrap(BrowserSearchEngine.google.searchURL(query: "hello world"))
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertEqual(url.path, "/search")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }

    func testDuckDuckGoSearchURL() throws {
        let url = try XCTUnwrap(BrowserSearchEngine.duckduckgo.searchURL(query: "hello world"))
        XCTAssertEqual(url.host, "duckduckgo.com")
        XCTAssertEqual(url.path, "/")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }

    func testBingSearchURL() throws {
        let url = try XCTUnwrap(BrowserSearchEngine.bing.searchURL(query: "hello world"))
        XCTAssertEqual(url.host, "www.bing.com")
        XCTAssertEqual(url.path, "/search")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }
}

final class BrowserHistoryStoreTests: XCTestCase {
    func testRecordVisitDedupesAndSuggests() async throws {
        let store = await MainActor.run { BrowserHistoryStore(fileURL: nil) }

        let u1 = try XCTUnwrap(URL(string: "https://example.com/foo"))
        let u2 = try XCTUnwrap(URL(string: "https://example.com/bar"))

        await MainActor.run {
            store.recordVisit(url: u1, title: "Example Foo")
            store.recordVisit(url: u2, title: "Example Bar")
            store.recordVisit(url: u1, title: "Example Foo Updated")
        }

        let suggestions = await MainActor.run { store.suggestions(for: "foo", limit: 10) }
        XCTAssertEqual(suggestions.first?.url, "https://example.com/foo")
        XCTAssertEqual(suggestions.first?.visitCount, 2)
        XCTAssertEqual(suggestions.first?.title, "Example Foo Updated")
    }
}

final class OmnibarStateMachineTests: XCTestCase {
    func testEscapeRevertsWhenEditingThenBlursOnSecondEscape() throws {
        var state = OmnibarState()

        var effects = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        XCTAssertTrue(state.isFocused)
        XCTAssertEqual(state.buffer, "https://example.com/")
        XCTAssertFalse(state.isUserEditing)
        XCTAssertTrue(effects.shouldSelectAll)

        effects = omnibarReduce(state: &state, event: .bufferChanged("exam"))
        XCTAssertTrue(state.isUserEditing)
        XCTAssertEqual(state.buffer, "exam")
        XCTAssertTrue(effects.shouldRefreshSuggestions)

        // Simulate an open popup.
        effects = omnibarReduce(
            state: &state,
            event: .suggestionsUpdated([.search(engineName: "Google", query: "exam")])
        )
        XCTAssertEqual(state.suggestions.count, 1)
        XCTAssertFalse(effects.shouldSelectAll)

        // First escape: revert + close popup + select-all.
        effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertEqual(state.buffer, "https://example.com/")
        XCTAssertFalse(state.isUserEditing)
        XCTAssertTrue(state.suggestions.isEmpty)
        XCTAssertTrue(effects.shouldSelectAll)
        XCTAssertFalse(effects.shouldBlurToWebView)

        // Second escape: blur (since we're not editing and popup is closed).
        effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertTrue(effects.shouldBlurToWebView)
    }

    func testPanelURLChangeDoesNotClobberUserBufferWhileEditing() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://a.test/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("hello"))
        XCTAssertTrue(state.isUserEditing)

        _ = omnibarReduce(state: &state, event: .panelURLChanged(currentURLString: "https://b.test/"))
        XCTAssertEqual(state.currentURLString, "https://b.test/")
        XCTAssertEqual(state.buffer, "hello")
        XCTAssertTrue(state.isUserEditing)

        let effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertEqual(state.buffer, "https://b.test/")
        XCTAssertTrue(effects.shouldSelectAll)
    }

    func testFocusLostRevertsUnlessSuppressed() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("typed"))
        XCTAssertEqual(state.buffer, "typed")

        _ = omnibarReduce(state: &state, event: .focusLostPreserveBuffer(currentURLString: "https://example.com/"))
        XCTAssertEqual(state.buffer, "typed")

        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("typed2"))
        _ = omnibarReduce(state: &state, event: .focusLostRevertBuffer(currentURLString: "https://example.com/"))
        XCTAssertEqual(state.buffer, "https://example.com/")
    }
}

@MainActor
final class NotificationDockBadgeTests: XCTestCase {
    func testDockBadgeLabelEnabledAndCounted() {
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 1, isEnabled: true), "1")
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 42, isEnabled: true), "42")
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 100, isEnabled: true), "99+")
    }

    func testDockBadgeLabelHiddenWhenDisabledOrZero() {
        XCTAssertNil(TerminalNotificationStore.dockBadgeLabel(unreadCount: 0, isEnabled: true))
        XCTAssertNil(TerminalNotificationStore.dockBadgeLabel(unreadCount: 5, isEnabled: false))
    }

    func testNotificationBadgePreferenceDefaultsToEnabled() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(NotificationBadgeSettings.isDockBadgeEnabled(defaults: defaults))

        defaults.set(false, forKey: NotificationBadgeSettings.dockBadgeEnabledKey)
        XCTAssertFalse(NotificationBadgeSettings.isDockBadgeEnabled(defaults: defaults))

        defaults.set(true, forKey: NotificationBadgeSettings.dockBadgeEnabledKey)
        XCTAssertTrue(NotificationBadgeSettings.isDockBadgeEnabled(defaults: defaults))
    }
}


final class MenuBarBadgeLabelFormatterTests: XCTestCase {
    func testBadgeLabelFormatting() {
        XCTAssertNil(MenuBarBadgeLabelFormatter.badgeText(for: 0))
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 1), "1")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 9), "9")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 10), "9+")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 47), "9+")
    }
}

final class NotificationMenuSnapshotBuilderTests: XCTestCase {
    func testSnapshotCountsUnreadAndLimitsRecentItems() {
        let notifications = (0..<8).map { index in
            TerminalNotification(
                id: UUID(),
                tabId: UUID(),
                surfaceId: nil,
                title: "N\(index)",
                subtitle: "",
                body: "",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isRead: index.isMultiple(of: 2)
            )
        }

        let snapshot = NotificationMenuSnapshotBuilder.make(
            notifications: notifications,
            maxInlineNotificationItems: 3
        )

        XCTAssertEqual(snapshot.unreadCount, 4)
        XCTAssertTrue(snapshot.hasNotifications)
        XCTAssertTrue(snapshot.hasUnreadNotifications)
        XCTAssertEqual(snapshot.recentNotifications.count, 3)
        XCTAssertEqual(snapshot.recentNotifications.map(\.id), Array(notifications.prefix(3)).map(\.id))
    }

    func testStateHintTitleHandlesSingularPluralAndZero() {
        XCTAssertEqual(NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 0), "No unread notifications")
        XCTAssertEqual(NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 1), "1 unread notification")
        XCTAssertEqual(NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 2), "2 unread notifications")
    }
}

final class MenuBarBuildHintFormatterTests: XCTestCase {
    func testReleaseBuildShowsNoHint() {
        XCTAssertNil(MenuBarBuildHintFormatter.menuTitle(appName: "cmux DEV menubar-extra", isDebugBuild: false))
    }

    func testDebugBuildWithTagShowsTag() {
        XCTAssertEqual(
            MenuBarBuildHintFormatter.menuTitle(appName: "cmux DEV menubar-extra", isDebugBuild: true),
            "Build Tag: menubar-extra"
        )
    }

    func testDebugBuildWithoutTagShowsUntagged() {
        XCTAssertEqual(
            MenuBarBuildHintFormatter.menuTitle(appName: "cmux DEV", isDebugBuild: true),
            "Build: DEV (untagged)"
        )
    }
}

final class MenuBarNotificationLineFormatterTests: XCTestCase {
    func testPlainTitleContainsUnreadDotBodyAndTab() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Build finished",
            subtitle: "",
            body: "All checks passed",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )

        let line = MenuBarNotificationLineFormatter.plainTitle(notification: notification, tabTitle: "workspace-1")
        XCTAssertTrue(line.hasPrefix("● Build finished"))
        XCTAssertTrue(line.contains("All checks passed"))
        XCTAssertTrue(line.contains("workspace-1"))
    }

    func testPlainTitleFallsBackToSubtitleWhenBodyEmpty() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Deploy",
            subtitle: "staging",
            body: "",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: true
        )

        let line = MenuBarNotificationLineFormatter.plainTitle(notification: notification, tabTitle: nil)
        XCTAssertTrue(line.hasPrefix("  Deploy"))
        XCTAssertTrue(line.contains("staging"))
    }

    func testMenuTitleWrapsAndTruncatesToThreeLines() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Extremely long notification title for wrapping behavior validation",
            subtitle: "",
            body: Array(repeating: "this body should wrap and eventually truncate", count: 8).joined(separator: " "),
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )

        let title = MenuBarNotificationLineFormatter.menuTitle(
            notification: notification,
            tabTitle: "workspace-with-a-very-long-name",
            maxWidth: 120,
            maxLines: 3
        )

        XCTAssertLessThanOrEqual(title.components(separatedBy: "\n").count, 3)
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testMenuTitlePreservesShortTextWithoutEllipsis() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Done",
            subtitle: "",
            body: "All checks passed",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )

        let title = MenuBarNotificationLineFormatter.menuTitle(
            notification: notification,
            tabTitle: "w1",
            maxWidth: 320,
            maxLines: 3
        )

        XCTAssertFalse(title.hasSuffix("…"))
    }
}


final class MenuBarIconDebugSettingsTests: XCTestCase {
    func testDisplayedUnreadCountUsesPreviewOverrideWhenEnabled() {
        let suiteName = "MenuBarIconDebugSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: MenuBarIconDebugSettings.previewEnabledKey)
        defaults.set(7, forKey: MenuBarIconDebugSettings.previewCountKey)

        XCTAssertEqual(MenuBarIconDebugSettings.displayedUnreadCount(actualUnreadCount: 2, defaults: defaults), 7)
    }

    func testBadgeRenderConfigClampsInvalidValues() {
        let suiteName = "MenuBarIconDebugSettingsTests.Clamp.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(-100, forKey: MenuBarIconDebugSettings.badgeRectXKey)
        defaults.set(200, forKey: MenuBarIconDebugSettings.badgeRectYKey)
        defaults.set(-100, forKey: MenuBarIconDebugSettings.singleDigitFontSizeKey)
        defaults.set(100, forKey: MenuBarIconDebugSettings.multiDigitXAdjustKey)

        let config = MenuBarIconDebugSettings.badgeRenderConfig(defaults: defaults)
        XCTAssertEqual(config.badgeRect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(config.badgeRect.origin.y, 20, accuracy: 0.001)
        XCTAssertEqual(config.singleDigitFontSize, 6, accuracy: 0.001)
        XCTAssertEqual(config.multiDigitXAdjust, 4, accuracy: 0.001)
    }

    func testBadgeRenderConfigUsesLegacySingleDigitXAdjustWhenNewKeyMissing() {
        let suiteName = "MenuBarIconDebugSettingsTests.LegacyX.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(2.5, forKey: MenuBarIconDebugSettings.legacySingleDigitXAdjustKey)

        let config = MenuBarIconDebugSettings.badgeRenderConfig(defaults: defaults)
        XCTAssertEqual(config.singleDigitXAdjust, 2.5, accuracy: 0.001)
    }
}

@MainActor

final class MenuBarIconRendererTests: XCTestCase {
    func testImageWidthDoesNotShiftWhenBadgeAppears() {
        let noBadge = MenuBarIconRenderer.makeImage(unreadCount: 0)
        let withBadge = MenuBarIconRenderer.makeImage(unreadCount: 2)

        XCTAssertEqual(noBadge.size.width, 18, accuracy: 0.001)
        XCTAssertEqual(withBadge.size.width, 18, accuracy: 0.001)
    }
}
