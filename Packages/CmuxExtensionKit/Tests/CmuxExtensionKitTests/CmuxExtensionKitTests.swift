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
        XCTAssertNil(CmuxExtensionJSONValue.number(Double(Int.max)).intValue)
        XCTAssertNil(CmuxExtensionJSONValue.number(Double.greatestFiniteMagnitude).intValue)
    }

    func testEventFrameDecodesSocketTimestamp() throws {
        let workspaceId = UUID()
        let data = Data("""
        {
          "seq": 12,
          "name": "workspace.selected",
          "category": "workspace",
          "source": "workspace.lifecycle",
          "occurred_at": "2026-05-21T10:00:00.123Z",
          "workspace_id": "\(workspaceId.uuidString)",
          "payload": {"workspace_id": "\(workspaceId.uuidString)"}
        }
        """.utf8)

        let event = try JSONDecoder().decode(CmuxExtensionEventFrame.self, from: data)

        XCTAssertEqual(event.sequence, 12)
        XCTAssertEqual(event.workspaceId, workspaceId)
        XCTAssertEqual(event.payload["workspace_id"]?.stringValue, workspaceId.uuidString)
        XCTAssertEqual(event.occurredAt.timeIntervalSince1970, 1_779_357_600.123, accuracy: 0.001)
    }

    func testSidebarSnapshotDecodesSocketShape() throws {
        let windowId = UUID()
        let workspaceId = UUID()
        let selectedId = workspaceId.uuidString
        let data = Data("""
        {
          "seq": 7,
          "window_id": "\(windowId.uuidString)",
          "selected_workspace_id": "\(selectedId)",
          "workspaces": [
            {
              "id": "\(workspaceId.uuidString)",
              "title": "API",
              "description": "Backend workspace",
              "pinned": true,
              "root_path": "/tmp/cmux/api",
              "project_root_path": "/tmp/cmux",
              "branch_summary": "main",
              "remote_display_target": "devbox",
              "remote_connection_state": "connected",
              "unread_count": 3,
              "latest_notification_text": "done",
              "latest_submitted_message": "ship",
              "latest_submitted_at": "2026-05-21T10:00:00.000Z",
              "listening_ports": [3000],
              "pull_request_urls": ["https://github.com/manaflow-ai/cmux/pull/4309"],
              "panel_directories": ["/tmp/cmux/api", "/tmp/cmux/web"],
              "git_branches": [
                {"branch": "main", "dirty": true},
                {"branch": "feature", "dirty": false}
              ]
            }
          ]
        }
        """.utf8)

        let snapshot = try JSONDecoder().decode(CmuxExtensionSidebarSnapshot.self, from: data)
        let workspace = try XCTUnwrap(snapshot.workspaces.first)

        XCTAssertEqual(snapshot.sequence, 7)
        XCTAssertEqual(snapshot.windowId, windowId)
        XCTAssertEqual(snapshot.selectedWorkspaceId, workspaceId)
        XCTAssertEqual(workspace.id, workspaceId)
        XCTAssertEqual(workspace.title, "API")
        XCTAssertEqual(workspace.customDescription, "Backend workspace")
        XCTAssertEqual(workspace.isPinned, true)
        XCTAssertEqual(workspace.rootPath, "/tmp/cmux/api")
        XCTAssertEqual(workspace.projectRootPath, "/tmp/cmux")
        XCTAssertEqual(workspace.branchSummary, "main")
        XCTAssertEqual(workspace.remoteDisplayTarget, "devbox")
        XCTAssertEqual(workspace.remoteConnectionState, "connected")
        XCTAssertEqual(workspace.unreadCount, 3)
        XCTAssertEqual(workspace.latestNotificationText, "done")
        XCTAssertEqual(workspace.latestSubmittedMessage, "ship")
        XCTAssertNotNil(workspace.latestSubmittedAt)
        XCTAssertEqual(workspace.listeningPorts, [3000])
        XCTAssertEqual(workspace.pullRequestURLs, ["https://github.com/manaflow-ai/cmux/pull/4309"])
        XCTAssertEqual(workspace.panelDirectories, ["/tmp/cmux/api", "/tmp/cmux/web"])
        XCTAssertEqual(workspace.gitBranches, [
            CmuxExtensionGitBranchSnapshot(branch: "main", isDirty: true),
            CmuxExtensionGitBranchSnapshot(branch: "feature", isDirty: false)
        ])
    }

    func testWorkspaceSnapshotDecodesSocketShapeDefaults() throws {
        let workspaceId = UUID()
        let data = Data("""
        {"id":"\(workspaceId.uuidString)","title":"API"}
        """.utf8)

        let workspace = try JSONDecoder().decode(CmuxExtensionWorkspaceSnapshot.self, from: data)

        XCTAssertEqual(workspace.id, workspaceId)
        XCTAssertEqual(workspace.title, "API")
        XCTAssertFalse(workspace.isPinned)
        XCTAssertEqual(workspace.unreadCount, 0)
        XCTAssertEqual(workspace.listeningPorts, [])
        XCTAssertEqual(workspace.pullRequestURLs, [])
        XCTAssertEqual(workspace.panelDirectories, [])
        XCTAssertEqual(workspace.gitBranches, [])
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

    func testBlankPromptSubmittedEventDoesNotAdvanceLastMessageProjection() {
        let existingDate = Date(timeIntervalSinceReferenceDate: 100)
        let workspace = workspace(
            title: "API",
            rootPath: "/tmp/cmux/api",
            projectRootPath: "/tmp/cmux",
            latestSubmittedMessage: "existing",
            latestSubmittedAt: existingDate
        )
        let event = CmuxExtensionEventFrame(
            sequence: 11,
            name: "workspace.prompt.submitted",
            category: "workspace",
            source: "workspace.prompt_submit",
            occurredAt: Date(timeIntervalSinceReferenceDate: 300),
            workspaceId: workspace.id,
            payload: [
                "message": .null,
                "message_preview": .null,
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
        XCTAssertEqual(updated.workspaces[0].latestSubmittedMessage, "existing")
        XCTAssertEqual(updated.workspaces[0].latestSubmittedAt, existingDate)
    }

    func testStaleEventFrameDoesNotMutateFreshSnapshot() {
        let existingDate = Date(timeIntervalSinceReferenceDate: 200)
        var workspace = workspace(
            title: "API",
            rootPath: "/tmp/cmux/api",
            projectRootPath: "/tmp/cmux",
            latestSubmittedMessage: "newer",
            latestSubmittedAt: existingDate
        )
        workspace.unreadCount = 1
        workspace.latestNotificationText = "fresh"
        let snapshot = CmuxExtensionSidebarSnapshot(
            sequence: 20,
            selectedWorkspaceId: workspace.id,
            workspaces: [workspace]
        )
        let staleNotification = CmuxExtensionEventFrame(
            sequence: 20,
            name: "notification.created",
            category: "notification",
            source: "notification.store",
            occurredAt: Date(timeIntervalSinceReferenceDate: 100),
            workspaceId: workspace.id,
            payload: [
                "body": .string("old notification"),
                "is_read": .bool(false)
            ]
        )
        let stalePrompt = CmuxExtensionEventFrame(
            sequence: 19,
            name: "workspace.prompt.submitted",
            category: "workspace",
            source: "workspace.prompt_submit",
            occurredAt: Date(timeIntervalSinceReferenceDate: 100),
            workspaceId: workspace.id,
            payload: [
                "message_preview": .string("older prompt")
            ]
        )

        let afterNotification = CmuxExtensionSidebarReducer.reduce(snapshot, event: staleNotification)
        let afterPrompt = CmuxExtensionSidebarReducer.reduce(snapshot, event: stalePrompt)

        XCTAssertEqual(afterNotification, snapshot)
        XCTAssertEqual(afterPrompt, snapshot)
    }

    func testWorkspacesReorderedHandlesDuplicatesAndPartialPayload() {
        let first = workspace(title: "First", rootPath: nil, projectRootPath: nil)
        let second = workspace(title: "Second", rootPath: nil, projectRootPath: nil)
        let third = workspace(title: "Third", rootPath: nil, projectRootPath: nil)
        let windowId = UUID()
        let snapshot = CmuxExtensionSidebarSnapshot(
            sequence: 5,
            selectedWorkspaceId: second.id,
            workspaces: [first, second, third],
            windowId: windowId
        )

        let updated = CmuxExtensionSidebarReducer.reduce(
            snapshot,
            event: .workspacesReordered([third.id, first.id, third.id])
        )

        XCTAssertEqual(updated.sequence, 6)
        XCTAssertEqual(updated.windowId, windowId)
        XCTAssertEqual(updated.selectedWorkspaceId, second.id)
        XCTAssertEqual(updated.workspaces.map(\.id), [third.id, first.id, second.id])
    }

    func testWorkspacesReorderedToleratesDuplicateWorkspaceSnapshots() {
        let first = workspace(title: "First", rootPath: nil, projectRootPath: nil)
        var replacement = workspace(title: "Replacement", rootPath: nil, projectRootPath: nil)
        replacement.id = first.id
        let snapshot = CmuxExtensionSidebarSnapshot(
            sequence: 5,
            selectedWorkspaceId: first.id,
            workspaces: [first, replacement]
        )

        let direct = CmuxExtensionSidebarReducer.reduce(
            snapshot,
            event: .workspacesReordered([first.id])
        )
        let frame = CmuxExtensionEventFrame(
            sequence: 8,
            name: "workspace.reordered",
            category: "workspace",
            source: "workspace.lifecycle",
            occurredAt: Date(timeIntervalSinceReferenceDate: 1),
            workspaceId: first.id,
            payload: [
                "workspace_ids": .array([.string(first.id.uuidString)])
            ]
        )
        let eventReduced = CmuxExtensionSidebarReducer.reduce(snapshot, event: frame)

        XCTAssertEqual(direct.workspaces.map(\.title), ["Replacement"])
        XCTAssertEqual(eventReduced.workspaces.map(\.title), ["Replacement"])
    }

    func testSidebarEventReducerPreservesWindowIdAcrossFreshSnapshots() {
        let first = workspace(title: "First", rootPath: nil, projectRootPath: nil)
        let second = workspace(title: "Second", rootPath: nil, projectRootPath: nil)
        let windowId = UUID()
        let snapshot = CmuxExtensionSidebarSnapshot(
            sequence: 1,
            selectedWorkspaceId: first.id,
            workspaces: [first],
            windowId: windowId
        )

        let upserted = CmuxExtensionSidebarReducer.reduce(snapshot, event: .workspaceUpserted(second))
        let selected = CmuxExtensionSidebarReducer.reduce(upserted, event: .workspaceSelected(second.id))
        let reordered = CmuxExtensionSidebarReducer.reduce(selected, event: .workspacesReordered([second.id, first.id]))
        let removed = CmuxExtensionSidebarReducer.reduce(reordered, event: .workspaceRemoved(first.id))

        XCTAssertEqual(upserted.windowId, windowId)
        XCTAssertEqual(selected.windowId, windowId)
        XCTAssertEqual(reordered.windowId, windowId)
        XCTAssertEqual(removed.windowId, windowId)
        XCTAssertEqual(removed.workspaces.map(\.id), [second.id])
    }

    func testWorkspaceReorderedEventPreservesFrameSequence() {
        let first = workspace(title: "First", rootPath: nil, projectRootPath: nil)
        var second = workspace(title: "Second", rootPath: nil, projectRootPath: nil)
        second.isPinned = true
        let snapshot = CmuxExtensionSidebarSnapshot(
            sequence: 10,
            selectedWorkspaceId: first.id,
            workspaces: [first, second]
        )
        let event = CmuxExtensionEventFrame(
            sequence: 12,
            name: "workspace.reordered",
            category: "workspace",
            source: "socket.v2",
            occurredAt: Date(timeIntervalSinceReferenceDate: 4),
            workspaceId: second.id,
            payload: [
                "workspace_ids": .array([.string(second.id.uuidString), .string(first.id.uuidString)]),
                "pinned_workspace_ids": .array([.string(first.id.uuidString)])
            ]
        )

        let updated = CmuxExtensionSidebarReducer.reduce(snapshot, event: event)

        XCTAssertEqual(updated.sequence, 12)
        XCTAssertEqual(updated.workspaces.map(\.id), [second.id, first.id])
        XCTAssertEqual(updated.workspaces.map(\.isPinned), [false, true])
    }

    func testWorkspaceReorderedEventWithoutLocalOverlapPreservesPinnedState() {
        var first = workspace(title: "First", rootPath: nil, projectRootPath: nil)
        first.isPinned = true
        let second = workspace(title: "Second", rootPath: nil, projectRootPath: nil)
        let foreign = UUID()
        let snapshot = CmuxExtensionSidebarSnapshot(
            sequence: 10,
            selectedWorkspaceId: first.id,
            workspaces: [first, second],
            windowId: UUID()
        )
        let event = CmuxExtensionEventFrame(
            sequence: 12,
            name: "workspace.reordered",
            category: "workspace",
            source: "workspace.lifecycle",
            occurredAt: Date(timeIntervalSinceReferenceDate: 4),
            workspaceId: foreign,
            payload: [
                "workspace_ids": .array([.string(foreign.uuidString)]),
                "pinned_workspace_ids": .array([.string(foreign.uuidString)])
            ]
        )

        let updated = CmuxExtensionSidebarReducer.reduce(snapshot, event: event)

        XCTAssertEqual(updated.sequence, 12)
        XCTAssertEqual(updated.workspaces.map(\.id), [first.id, second.id])
        XCTAssertEqual(updated.workspaces.map(\.isPinned), [true, false])
    }

    func testWorkspaceReorderedEventReadsSocketResultIndex() {
        let first = workspace(title: "First", rootPath: nil, projectRootPath: nil)
        let second = workspace(title: "Second", rootPath: nil, projectRootPath: nil)
        let third = workspace(title: "Third", rootPath: nil, projectRootPath: nil)
        let snapshot = CmuxExtensionSidebarSnapshot(
            sequence: 20,
            selectedWorkspaceId: first.id,
            workspaces: [first, second, third]
        )
        let event = CmuxExtensionEventFrame(
            sequence: 21,
            name: "workspace.reordered",
            category: "workspace",
            source: "socket.v2",
            occurredAt: Date(timeIntervalSinceReferenceDate: 6),
            workspaceId: third.id,
            payload: [
                "method": .string("workspace.reorder"),
                "params": .object([
                    "workspace_id": .string(third.id.uuidString),
                    "index": .number(0)
                ]),
                "result": .object([
                    "workspace_id": .string(third.id.uuidString),
                    "index": .number(0)
                ])
            ]
        )

        let updated = CmuxExtensionSidebarReducer.reduce(snapshot, event: event)

        XCTAssertEqual(updated.sequence, 21)
        XCTAssertEqual(updated.workspaces.map(\.id), [third.id, first.id, second.id])
    }

    func testWorkspaceCreatedEventAddsWorkspaceProjection() {
        let first = workspace(title: "First", rootPath: "/tmp/cmux/first", projectRootPath: "/tmp/cmux")
        let createdId = UUID()
        let snapshot = CmuxExtensionSidebarSnapshot(
            sequence: 5,
            selectedWorkspaceId: first.id,
            workspaces: [first]
        )
        let event = CmuxExtensionEventFrame(
            sequence: 6,
            name: "workspace.created",
            category: "workspace",
            source: "workspace.lifecycle",
            occurredAt: Date(timeIntervalSinceReferenceDate: 2),
            workspaceId: createdId,
            payload: [
                "workspace_id": .string(createdId.uuidString),
                "title": .string("Created"),
                "cwd": .string("/tmp/cmux/created"),
                "index": .number(0),
                "selected": .bool(true)
            ]
        )

        XCTAssertTrue(CmuxExtensionSidebarReducer.requiresSnapshotReplacement(after: event))

        let updated = CmuxExtensionSidebarReducer.reduce(snapshot, event: event)

        XCTAssertEqual(updated.sequence, 6)
        XCTAssertEqual(updated.selectedWorkspaceId, createdId)
        XCTAssertEqual(updated.workspaces.map(\.id), [createdId, first.id])
        XCTAssertEqual(updated.workspaces[0].title, "Created")
        XCTAssertEqual(updated.workspaces[0].rootPath, "/tmp/cmux/created")
    }

    func testWorkspaceSelectedEventIgnoresWorkspaceOutsideSnapshotWindow() {
        let first = workspace(title: "First", rootPath: "/tmp/cmux/first", projectRootPath: "/tmp/cmux")
        let secondWindowWorkspaceId = UUID()
        let snapshot = CmuxExtensionSidebarSnapshot(
            sequence: 1,
            selectedWorkspaceId: first.id,
            workspaces: [first],
            windowId: UUID()
        )
        let event = CmuxExtensionEventFrame(
            sequence: 2,
            name: "workspace.selected",
            category: "workspace",
            source: "workspace.lifecycle",
            occurredAt: Date(timeIntervalSinceReferenceDate: 1),
            workspaceId: secondWindowWorkspaceId
        )

        let updated = CmuxExtensionSidebarReducer.reduce(snapshot, event: event)

        XCTAssertEqual(updated.sequence, 2)
        XCTAssertEqual(updated.selectedWorkspaceId, first.id)
    }

    func testWorkspaceRenamedEventReadsSocketResultPayload() {
        let first = workspace(title: "Before", rootPath: "/tmp/cmux/first", projectRootPath: "/tmp/cmux")
        let snapshot = CmuxExtensionSidebarSnapshot(
            sequence: 7,
            selectedWorkspaceId: first.id,
            workspaces: [first]
        )
        let event = CmuxExtensionEventFrame(
            sequence: 8,
            name: "workspace.renamed",
            category: "workspace",
            source: "socket.v2",
            occurredAt: Date(timeIntervalSinceReferenceDate: 5),
            workspaceId: first.id,
            payload: [
                "method": .string("workspace.rename"),
                "result": .object([
                    "workspace_id": .string(first.id.uuidString),
                    "title": .string("After")
                ])
            ]
        )

        let updated = CmuxExtensionSidebarReducer.reduce(snapshot, event: event)

        XCTAssertEqual(updated.sequence, 8)
        XCTAssertEqual(updated.workspaces[0].title, "After")
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

    func testNotificationCreatedEventUpdatesUnreadProjection() {
        let workspace = workspace(title: "API", rootPath: "/tmp/cmux/api", projectRootPath: "/tmp/cmux")
        let snapshot = CmuxExtensionSidebarSnapshot(
            sequence: 30,
            selectedWorkspaceId: workspace.id,
            workspaces: [workspace]
        )
        let event = CmuxExtensionEventFrame(
            sequence: 31,
            name: "notification.created",
            category: "notification",
            source: "notification.store",
            occurredAt: Date(timeIntervalSinceReferenceDate: 7),
            workspaceId: workspace.id,
            payload: [
                "notification_id": .string(UUID().uuidString),
                "workspace_id": .string(workspace.id.uuidString),
                "title": .string("Done"),
                "body": .string("  build   passed  "),
                "is_read": .bool(false)
            ]
        )

        let updated = CmuxExtensionSidebarReducer.reduce(snapshot, event: event)

        XCTAssertFalse(CmuxExtensionSidebarReducer.requiresSnapshotReplacement(after: event))
        XCTAssertEqual(updated.sequence, 31)
        XCTAssertEqual(updated.workspaces[0].unreadCount, 1)
        XCTAssertEqual(updated.workspaces[0].latestNotificationText, "build passed")
    }

    func testNotificationReadEventUpdatesUnreadProjection() {
        var workspace = workspace(title: "API", rootPath: "/tmp/cmux/api", projectRootPath: "/tmp/cmux")
        workspace.unreadCount = 2
        workspace.latestNotificationText = "done"
        let snapshot = CmuxExtensionSidebarSnapshot(
            sequence: 31,
            selectedWorkspaceId: workspace.id,
            workspaces: [workspace]
        )
        let event = CmuxExtensionEventFrame(
            sequence: 32,
            name: "notification.read",
            category: "notification",
            source: "notification.store",
            occurredAt: Date(timeIntervalSinceReferenceDate: 8),
            workspaceId: workspace.id,
            payload: [
                "notification_ids": .array([.string(UUID().uuidString), .string(UUID().uuidString)]),
                "count": .number(2)
            ]
        )

        let updated = CmuxExtensionSidebarReducer.reduce(snapshot, event: event)

        XCTAssertTrue(CmuxExtensionSidebarReducer.requiresSnapshotReplacement(after: event))
        XCTAssertEqual(updated.sequence, 32)
        XCTAssertEqual(updated.workspaces[0].unreadCount, 0)
        XCTAssertNil(updated.workspaces[0].latestNotificationText)
    }

    func testRedactedNotificationAndSidebarEventsRequireSnapshotReplacement() {
        let workspaceId = UUID()
        let redactedNotification = CmuxExtensionEventFrame(
            sequence: 40,
            name: "notification.created",
            category: "notification",
            source: "notification.store",
            occurredAt: Date(timeIntervalSinceReferenceDate: 9),
            workspaceId: workspaceId,
            payload: [
                "title": .null,
                "body": .null,
                "redacted_fields": .array([.string("title"), .string("body")])
            ]
        )
        let sidebarMetadata = CmuxExtensionEventFrame(
            sequence: 41,
            name: "sidebar.metadata.updated",
            category: "sidebar",
            source: "socket.v1",
            occurredAt: Date(timeIntervalSinceReferenceDate: 10),
            workspaceId: workspaceId
        )
        let promptSubmitted = CmuxExtensionEventFrame(
            sequence: 42,
            name: "workspace.prompt.submitted",
            category: "workspace",
            source: "workspace.prompt_submit",
            occurredAt: Date(timeIntervalSinceReferenceDate: 11),
            workspaceId: workspaceId,
            payload: ["message_preview": .string("ship")]
        )
        let workspaceAction = CmuxExtensionEventFrame(
            sequence: 43,
            name: "workspace.action",
            category: "workspace",
            source: "socket.v2",
            occurredAt: Date(timeIntervalSinceReferenceDate: 12),
            workspaceId: workspaceId,
            payload: ["method": .string("workspace.pin")]
        )
        let workspaceMoved = CmuxExtensionEventFrame(
            sequence: 44,
            name: "workspace.moved",
            category: "workspace",
            source: "socket.v2",
            occurredAt: Date(timeIntervalSinceReferenceDate: 13),
            workspaceId: workspaceId,
            payload: ["method": .string("workspace.move_to_window")]
        )

        XCTAssertTrue(CmuxExtensionSidebarReducer.requiresSnapshotReplacement(after: redactedNotification))
        XCTAssertTrue(CmuxExtensionSidebarReducer.requiresSnapshotReplacement(after: sidebarMetadata))
        XCTAssertTrue(CmuxExtensionSidebarReducer.requiresSnapshotReplacement(after: workspaceAction))
        XCTAssertTrue(CmuxExtensionSidebarReducer.requiresSnapshotReplacement(after: workspaceMoved))
        XCTAssertFalse(CmuxExtensionSidebarReducer.requiresSnapshotReplacement(after: promptSubmitted))
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
