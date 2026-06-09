import CmuxSidebarProviderKit
@testable import CmuxExtensionSidebarExamples
import XCTest

final class BrowserStackSidebarTests: XCTestCase {
    func testGroupingAndOrderPersistAcrossProviderInstances() throws {
        let stateURL = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }

        let snapshot = snapshot(titles: [
            "Hacker News",
            "Google",
            "X. It's what's happening / X",
            "Meaning Of Life",
            "Dia Browser | Latest Release Notes",
            "end",
            "cmux hibernation",
            "sidebar full customization",
            "history",
        ])
        let store = BrowserStackSidebarStore(stateURL: stateURL)
        let provider = BrowserStackSidebar(store: store)

        let initialModel = provider.render(snapshot: snapshot)

        XCTAssertEqual(initialModel.presentation, .browserStack)
        XCTAssertEqual(initialModel.sections.map(\.id), ["tiles", "loose", "group:reading-list"])
        XCTAssertEqual(initialModel.sections[0].rows.map(\.title), [
            "Hacker News",
            "Google",
            "X. It's what's happening / X",
        ])

        let movedWorkspace = snapshot.workspaces[3]
        let result = try provider.handle(
            .moveWorkspace(
                CmuxSidebarProviderWorkspaceMove(
                    workspaceId: movedWorkspace.id,
                    sourceSectionId: "loose",
                    targetSectionId: "group:reading-list",
                    targetIndex: 0
                )
            ),
            snapshot: snapshot
        )

        XCTAssertTrue(result.ok)

        let updatedModel = provider.render(snapshot: snapshot)
        let updatedGroupRows = try XCTUnwrap(updatedModel.sections.first { $0.id == "group:reading-list" }?.rows)
        XCTAssertEqual(updatedGroupRows.first?.workspaceId, movedWorkspace.id)

        let persistedState = try waitForPersistedState(store: store) { state in
            state.sections.first { $0.id == "group:reading-list" }?.workspaceIds.first == movedWorkspace.id
        }
        let reopenedProvider = BrowserStackSidebar(store: store, initialState: persistedState)
        let reopenedModel = reopenedProvider.render(snapshot: snapshot)
        let groupRows = try XCTUnwrap(reopenedModel.sections.first { $0.id == "group:reading-list" }?.rows)
        let groupState = try XCTUnwrap(persistedState.sections.first { $0.id == "group:reading-list" })

        XCTAssertEqual(groupRows.first?.workspaceId, movedWorkspace.id)
        XCTAssertEqual(groupState.workspaceIds.first, movedWorkspace.id)
    }

    func testReconcilePreservesUserStateWhileApplyingSnapshotMembership() throws {
        let stateURL = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }

        let first = workspace(title: "First")
        let removed = workspace(title: "Removed")
        let added = workspace(title: "Added Later")
        let store = BrowserStackSidebarStore(stateURL: stateURL)
        try store.save(
            BrowserStackSidebarState(sections: [
                BrowserStackSidebarSectionState(
                    id: "tiles",
                    title: "Pinned",
                    kind: .tiles,
                    workspaceIds: [first.id, removed.id]
                ),
                BrowserStackSidebarSectionState(
                    id: "loose",
                    title: "Open",
                    kind: .loose,
                    workspaceIds: []
                ),
                BrowserStackSidebarSectionState(
                    id: "group:research",
                    title: "research",
                    kind: .group,
                    workspaceIds: []
                ),
            ])
        )

        let reconciled = try store.reconciledState(for: CmuxSidebarProviderSnapshot(
            sequence: 2,
            selectedWorkspaceId: nil,
            workspaces: [first, added]
        ))

        XCTAssertEqual(reconciled.sections.first { $0.id == "tiles" }?.workspaceIds, [first.id])
        XCTAssertEqual(reconciled.sections.first { $0.id == "loose" }?.workspaceIds, [added.id])
        XCTAssertEqual(reconciled.sections.map(\.id), ["tiles", "loose", "group:research"])
    }

    func testWindowScopedStateDoesNotTruncateOtherWindowOrdering() throws {
        let stateURL = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }

        let firstWindowId = UUID()
        let secondWindowId = UUID()
        let firstSnapshot = snapshot(titles: ["First A", "First B", "First C", "First D"], windowId: firstWindowId)
        let secondSnapshot = snapshot(titles: ["Second A", "Second B", "Second C", "Second D"], windowId: secondWindowId)
        let store = BrowserStackSidebarStore(stateURL: stateURL)
        let provider = BrowserStackSidebar(store: store)

        _ = provider.render(snapshot: firstSnapshot)
        _ = provider.render(snapshot: secondSnapshot)

        let movedWorkspace = firstSnapshot.workspaces[3]
        let result = try provider.handle(
            .moveWorkspace(
                CmuxSidebarProviderWorkspaceMove(
                    workspaceId: movedWorkspace.id,
                    sourceSectionId: "loose",
                    targetSectionId: "group:reading-list",
                    targetIndex: 0
                )
            ),
            snapshot: firstSnapshot
        )

        XCTAssertTrue(result.ok)
        _ = provider.render(snapshot: secondSnapshot)
        let secondMovedWorkspace = secondSnapshot.workspaces[3]
        XCTAssertTrue(try provider.handle(
            .moveWorkspace(
                CmuxSidebarProviderWorkspaceMove(
                    workspaceId: secondMovedWorkspace.id,
                    sourceSectionId: "loose",
                    targetSectionId: "group:reading-list",
                    targetIndex: 0
                )
            ),
            snapshot: secondSnapshot
        ).ok)
        let firstModel = provider.render(snapshot: firstSnapshot)
        let firstGroupRows = try XCTUnwrap(firstModel.sections.first { $0.id == "group:reading-list" }?.rows)
        XCTAssertEqual(firstGroupRows.first?.workspaceId, movedWorkspace.id)

        let persistedState = try waitForPersistedState(store: store, scopeKey: scopeKey(for: firstWindowId)) { state in
            state.sections.first { $0.id == "group:reading-list" }?.workspaceIds.first == movedWorkspace.id
        }
        let secondScopedState = try waitForPersistedState(store: store, scopeKey: scopeKey(for: secondWindowId)) { state in
            state.sections.first { $0.id == "group:reading-list" }?.workspaceIds.first == secondMovedWorkspace.id
        }

        XCTAssertEqual(persistedState.sections.first { $0.id == "group:reading-list" }?.workspaceIds.first, movedWorkspace.id)
        XCTAssertEqual(secondScopedState.sections.first { $0.id == "group:reading-list" }?.workspaceIds.first, secondMovedWorkspace.id)
        XCTAssertFalse(secondScopedState.sections.flatMap(\.workspaceIds).contains(movedWorkspace.id))
    }

    func testWindowScopedStateFallsBackToMatchingRelaunchScope() throws {
        let stateURL = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }

        let oldWindowId = UUID()
        let newWindowId = UUID()
        let otherWindowId = UUID()
        let oldSnapshot = snapshot(titles: ["First A", "First B", "First C", "First D"], windowId: oldWindowId)
        let otherSnapshot = snapshot(titles: ["Other A", "Other B", "Other C", "Other D"], windowId: otherWindowId)
        let movedWorkspace = oldSnapshot.workspaces[3]
        let store = BrowserStackSidebarStore(stateURL: stateURL)

        var preferredState = BrowserStackSidebarState.initial(snapshot: oldSnapshot)
        preferredState.moveWorkspace(CmuxSidebarProviderWorkspaceMove(
            workspaceId: movedWorkspace.id,
            sourceSectionId: "loose",
            targetSectionId: "group:reading-list",
            targetIndex: 0
        ))
        try store.save(preferredState.reconciled(with: oldSnapshot), scopeKey: scopeKey(for: oldWindowId))
        try store.save(BrowserStackSidebarState.initial(snapshot: otherSnapshot), scopeKey: scopeKey(for: otherWindowId))

        let relaunchedSnapshot = CmuxSidebarProviderSnapshot(
            sequence: 2,
            selectedWorkspaceId: oldSnapshot.selectedWorkspaceId,
            workspaces: oldSnapshot.workspaces,
            windowId: newWindowId
        )
        let loaded = try store.load(scopeKey: scopeKey(for: newWindowId), snapshot: relaunchedSnapshot)

        XCTAssertEqual(loaded.sections.first { $0.id == "group:reading-list" }?.workspaceIds.first, movedWorkspace.id)
    }

    func testBrowserStackRenderModelPreservesEmptyRequiredSections() {
        let snapshot = CmuxSidebarProviderSnapshot(sequence: 1, selectedWorkspaceId: nil, workspaces: [])
        let sections = [
            ExampleSidebarSection(
                id: "tiles",
                title: localized("example.sidebar.tiles", "Pinned"),
                systemImageName: "rectangle.grid.3x2",
                projectRootPath: nil,
                workspaces: []
            ).render(),
            ExampleSidebarSection(
                id: "loose",
                title: localized("example.sidebar.loose", "Open"),
                systemImageName: "globe",
                projectRootPath: nil,
                workspaces: []
            ).render()
        ]

        let model = renderModel(
            providerId: "browser-stack",
            snapshot: snapshot,
            sections: sections,
            presentation: .browserStack
        )

        XCTAssertEqual(model.sections.map(\.id), ["tiles", "loose"])
    }

    func testAsyncStateLoadNotifiesHostAndUpdatesRenderModel() throws {
        let stateURL = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }

        let workspaces = [
            workspace(title: "First"),
            workspace(title: "Second"),
            workspace(title: "Third"),
            workspace(title: "Fourth"),
        ]
        let snapshot = CmuxSidebarProviderSnapshot(
            sequence: 1,
            selectedWorkspaceId: nil,
            workspaces: workspaces
        )
        let store = BrowserStackSidebarStore(stateURL: stateURL)
        try store.save(BrowserStackSidebarState(sections: [
            BrowserStackSidebarSectionState(
                id: "tiles",
                title: "Pinned",
                kind: .tiles,
                workspaceIds: [workspaces[1].id]
            ),
            BrowserStackSidebarSectionState(
                id: "loose",
                title: "Open",
                kind: .loose,
                workspaceIds: [workspaces[0].id, workspaces[2].id]
            ),
            BrowserStackSidebarSectionState(
                id: "group:reading-list",
                title: "Reading List",
                kind: .group,
                workspaceIds: [workspaces[3].id]
            ),
        ]))
        let loaded = expectation(description: "async state loaded")
        let probe = AsyncStateLoadProbe(loaded)
        let provider = BrowserStackSidebar(store: store, onAsyncStateLoaded: {
            probe.fulfill()
        })

        _ = provider.render(snapshot: snapshot)
        wait(for: [loaded], timeout: 2)
        let model = provider.render(snapshot: snapshot)

        XCTAssertEqual(model.sections.first { $0.id == "tiles" }?.rows.map(\.workspaceId), [workspaces[1].id])
        XCTAssertEqual(
            model.sections.first { $0.id == "group:reading-list" }?.rows.map(\.workspaceId),
            [workspaces[3].id]
        )
    }

    func testBrowserIconOnlyMatchesYcAsToken() throws {
        let stateURL = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }

        let snapshot = snapshot(titles: ["privacy", "YC launch"])
        let model = BrowserStackSidebar(store: BrowserStackSidebarStore(stateURL: stateURL)).render(snapshot: snapshot)
        let rows = try XCTUnwrap(model.sections.first { $0.id == "tiles" }?.rows)

        XCTAssertNotEqual(rows[0].leadingIcon?.text, "Y")
        XCTAssertEqual(rows[1].leadingIcon?.text, "Y")
    }

    func testBrowserIconOnlyMatchesDiaAsToken() throws {
        let stateURL = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }

        let snapshot = snapshot(titles: ["Canadian docs", "Dia Browser"])
        let model = BrowserStackSidebar(store: BrowserStackSidebarStore(stateURL: stateURL)).render(snapshot: snapshot)
        let rows = try XCTUnwrap(model.sections.first { $0.id == "tiles" }?.rows)

        XCTAssertEqual(rows[0].leadingIcon?.backgroundColorHex, "#5A5A5A")
        XCTAssertEqual(rows[1].leadingIcon?.backgroundColorHex, "#000000")
    }

    func testRenderToleratesDuplicateWorkspaceIds() throws {
        let stateURL = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }

        let original = workspace(title: "Original")
        var replacement = workspace(title: "Replacement")
        replacement.id = original.id
        let snapshot = CmuxSidebarProviderSnapshot(
            sequence: 1,
            selectedWorkspaceId: original.id,
            workspaces: [original, replacement]
        )

        let model = BrowserStackSidebar(store: BrowserStackSidebarStore(stateURL: stateURL)).render(snapshot: snapshot)
        let rows = try XCTUnwrap(model.sections.first { $0.id == "tiles" }?.rows)

        XCTAssertEqual(rows.map(\.workspaceId), [original.id])
        XCTAssertEqual(rows.map(\.title), ["Replacement"])
    }

    private func temporaryStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-stack-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    private func waitForPersistedState(
        store: BrowserStackSidebarStore,
        scopeKey: String? = nil,
        timeout: TimeInterval = 2,
        matching predicate: (BrowserStackSidebarState) -> Bool
    ) throws -> BrowserStackSidebarState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = scopeKey.flatMap { try? store.load(scopeKey: $0) } ?? (try? store.load())
            if let state, predicate(state) {
                return state
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if let scopeKey {
            return try store.load(scopeKey: scopeKey)
        }
        return try store.load()
    }

    private func snapshot(titles: [String], windowId: UUID? = nil) -> CmuxSidebarProviderSnapshot {
        let workspaces = titles.map { workspace(title: $0) }
        return CmuxSidebarProviderSnapshot(
            sequence: 1,
            selectedWorkspaceId: workspaces.first?.id,
            workspaces: workspaces,
            windowId: windowId
        )
    }

    private func scopeKey(for windowId: UUID) -> String {
        "window-\(windowId.uuidString.lowercased())"
    }

    private func workspace(title: String) -> CmuxSidebarProviderWorkspace {
        CmuxSidebarProviderWorkspace(
            id: UUID(),
            title: title,
            customDescription: nil,
            isPinned: false,
            rootPath: nil,
            projectRootPath: nil,
            branchSummary: nil,
            remoteDisplayTarget: nil,
            remoteConnectionState: nil,
            unreadCount: 0,
            latestNotificationText: nil,
            listeningPorts: []
        )
    }
}

private final class AsyncStateLoadProbe: @unchecked Sendable {
    private let expectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func fulfill() {
        expectation.fulfill()
    }
}
