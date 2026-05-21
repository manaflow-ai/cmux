import CmuxExtensionKit
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
                CmuxExtensionSidebarWorkspaceMove(
                    workspaceId: movedWorkspace.id,
                    sourceSectionId: "loose",
                    targetSectionId: "group:reading-list",
                    targetIndex: 0
                )
            ),
            snapshot: snapshot
        )

        XCTAssertTrue(result.ok)

        let reopenedProvider = BrowserStackSidebar(store: store, initialState: try store.load())
        let reopenedModel = reopenedProvider.render(snapshot: snapshot)
        let persistedState = try store.load()
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

        let reconciled = try store.reconciledState(for: CmuxExtensionSidebarSnapshot(
            sequence: 2,
            selectedWorkspaceId: nil,
            workspaces: [first, added]
        ))

        XCTAssertEqual(reconciled.sections.first { $0.id == "tiles" }?.workspaceIds, [first.id])
        XCTAssertEqual(reconciled.sections.first { $0.id == "loose" }?.workspaceIds, [added.id])
        XCTAssertEqual(reconciled.sections.map(\.id), ["tiles", "loose", "group:research"])
    }

    func testBrowserStackRenderModelPreservesEmptyRequiredSections() {
        let snapshot = CmuxExtensionSidebarSnapshot(sequence: 1, selectedWorkspaceId: nil, workspaces: [])
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
        let snapshot = CmuxExtensionSidebarSnapshot(
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

    private func temporaryStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-stack-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    private func snapshot(titles: [String]) -> CmuxExtensionSidebarSnapshot {
        let workspaces = titles.map { workspace(title: $0) }
        return CmuxExtensionSidebarSnapshot(
            sequence: 1,
            selectedWorkspaceId: workspaces.first?.id,
            workspaces: workspaces
        )
    }

    private func workspace(title: String) -> CmuxExtensionWorkspaceSnapshot {
        CmuxExtensionWorkspaceSnapshot(
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
