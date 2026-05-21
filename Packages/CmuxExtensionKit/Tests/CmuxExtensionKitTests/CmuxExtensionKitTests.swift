import XCTest
@testable import CmuxExtensionKit

final class CmuxExtensionKitTests: XCTestCase {
    func testDefaultProviderDescriptorIsStable() {
        XCTAssertEqual(CmuxExtensionSidebarProviderDescriptor.defaultWorkspaces.id, "cmux.sidebar.default")
        XCTAssertEqual(CmuxExtensionSidebarProviderDescriptor.defaultWorkspaces.isHostProvided, true)
    }

    func testPresentationRequestCodableRoundTrips() throws {
        let workspaceId = UUID()
        let request = CmuxExtensionSidebarPresentationRequest.openWorkspaceWindow(
            workspaceId: workspaceId,
            preferredTab: .browser
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(CmuxExtensionSidebarPresentationRequest.self, from: data)

        XCTAssertEqual(decoded, request)
    }

    func testWorkspacePopoverTabRoundTripsActiveCases() throws {
        for tab in [CmuxExtensionWorkspacePopoverTab.notes, .browser] {
            let data = try JSONEncoder().encode(tab)
            let decoded = try JSONDecoder().decode(CmuxExtensionWorkspacePopoverTab.self, from: data)

            XCTAssertEqual(decoded, tab)
        }
    }

    func testJSONValueIntValueReturnsNilForOutOfRangeNumber() {
        XCTAssertEqual(CmuxExtensionJSONValue.number(42).intValue, 42)
        XCTAssertNil(CmuxExtensionJSONValue.number(1.5).intValue)
        XCTAssertNil(CmuxExtensionJSONValue.number(Double.greatestFiniteMagnitude).intValue)
    }

    func testLegacyPullRequestTabDecodesAsBrowser() throws {
        let data = try JSONEncoder().encode("pullRequest")
        let decoded = try JSONDecoder().decode(CmuxExtensionWorkspacePopoverTab.self, from: data)

        XCTAssertEqual(decoded, .browser)
    }

    func testLegacyRenderModelDecodesWithTreePresentation() throws {
        let data = Data("""
        {"providerId":"legacy","snapshotSequence":1,"sections":[]}
        """.utf8)

        let decoded = try JSONDecoder().decode(CmuxExtensionSidebarRenderModel.self, from: data)

        XCTAssertEqual(decoded.presentation, .tree)
    }

    func testMoveWorkspaceMutationCodableRoundTrips() throws {
        let move = CmuxExtensionSidebarWorkspaceMove(
            workspaceId: UUID(),
            sourceSectionId: "loose",
            targetSectionId: "group:research",
            targetIndex: 2
        )
        let mutation = CmuxExtensionSidebarMutation.moveWorkspace(move)

        let data = try JSONEncoder().encode(mutation)
        let decoded = try JSONDecoder().decode(CmuxExtensionSidebarMutation.self, from: data)

        XCTAssertEqual(decoded, mutation)
    }

    func testPromptSubmittedEventUpdatesLastMessageProjection() {
        let workspace = workspace(title: "API", rootPath: "/tmp/cmux/api", projectRootPath: "/tmp/cmux")
        let date = Date(timeIntervalSinceReferenceDate: 300)
        let event = CmuxExtensionEventFrame(
            sequence: 11,
            name: "workspace.prompt.submitted",
            category: "workspace",
            source: "workspace.prompt_submit",
            occurredAt: date,
            workspaceId: workspace.id,
            payload: [
                "message": .null,
                "message_preview": .string("  ship   the   events  "),
                "redacted_fields": .array([.string("message")])
            ]
        )
        let snapshot = CmuxExtensionSidebarSnapshot(
            sequence: 10,
            selectedWorkspaceId: nil,
            workspaces: [workspace]
        )

        let updated = CmuxExtensionSidebarReducer.reduce(snapshot, event: event)

        XCTAssertEqual(updated.sequence, 11)
        XCTAssertEqual(updated.workspaces[0].latestSubmittedMessage, "ship the events")
        XCTAssertEqual(updated.workspaces[0].latestSubmittedAt, date)
    }

    func testWorkspacesReorderedHandlesDuplicatesAndPartialPayload() {
        let first = workspace(title: "First", rootPath: nil, projectRootPath: nil)
        let second = workspace(title: "Second", rootPath: nil, projectRootPath: nil)
        let third = workspace(title: "Third", rootPath: nil, projectRootPath: nil)
        let snapshot = CmuxExtensionSidebarSnapshot(
            sequence: 5,
            selectedWorkspaceId: second.id,
            workspaces: [first, second, third]
        )

        let updated = CmuxExtensionSidebarReducer.reduce(
            snapshot,
            event: .workspacesReordered([third.id, first.id, third.id])
        )

        XCTAssertEqual(updated.sequence, 6)
        XCTAssertEqual(updated.selectedWorkspaceId, second.id)
        XCTAssertEqual(updated.workspaces.map(\.id), [third.id, first.id, second.id])
    }

    func testSelectedAndClosedWorkspaceEventsUpdateProjection() {
        let first = workspace(title: "First", rootPath: "/tmp/cmux/first", projectRootPath: "/tmp/cmux")
        let second = workspace(title: "Second", rootPath: "/tmp/cmux/second", projectRootPath: "/tmp/cmux")
        let snapshot = CmuxExtensionSidebarSnapshot(
            sequence: 1,
            selectedWorkspaceId: nil,
            workspaces: [first, second]
        )
        let selected = CmuxExtensionEventFrame(
            sequence: 2,
            name: "workspace.selected",
            category: "workspace",
            source: "workspace.lifecycle",
            occurredAt: Date(timeIntervalSinceReferenceDate: 1),
            workspaceId: second.id
        )
        let closed = CmuxExtensionEventFrame(
            sequence: 3,
            name: "workspace.closed",
            category: "workspace",
            source: "workspace.lifecycle",
            occurredAt: Date(timeIntervalSinceReferenceDate: 2),
            workspaceId: second.id
        )

        let selectedSnapshot = CmuxExtensionSidebarReducer.reduce(snapshot, event: selected)
        let closedSnapshot = CmuxExtensionSidebarReducer.reduce(selectedSnapshot, event: closed)

        XCTAssertEqual(selectedSnapshot.selectedWorkspaceId, second.id)
        XCTAssertEqual(closedSnapshot.selectedWorkspaceId, nil)
        XCTAssertEqual(closedSnapshot.workspaces.map(\.id), [first.id])
    }

    private func workspace(
        title: String,
        rootPath: String?,
        projectRootPath: String?,
        latestSubmittedMessage: String? = nil,
        latestSubmittedAt: Date? = nil
    ) -> CmuxExtensionWorkspaceSnapshot {
        CmuxExtensionWorkspaceSnapshot(
            id: UUID(),
            title: title,
            customDescription: nil,
            isPinned: false,
            rootPath: rootPath,
            projectRootPath: projectRootPath,
            branchSummary: nil,
            remoteDisplayTarget: nil,
            remoteConnectionState: nil,
            unreadCount: 0,
            latestNotificationText: nil,
            latestSubmittedMessage: latestSubmittedMessage,
            latestSubmittedAt: latestSubmittedAt,
            listeningPorts: []
        )
    }
}
