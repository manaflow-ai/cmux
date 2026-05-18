import XCTest
@testable import CmuxExtensionKit

final class CmuxExtensionKitTests: XCTestCase {
    func testBuiltInProviderIDsAreStable() {
        XCTAssertEqual(CmuxExtensionSidebarProviderDescriptor.projectTree.id, "cmux.sidebar.project-tree")
        XCTAssertEqual(CmuxExtensionSidebarProviderDescriptor.attention.mode, .attention)
        XCTAssertEqual(CmuxExtensionSidebarProviderDescriptor.servers.mode, .servers)
        XCTAssertEqual(CmuxExtensionSidebarProviderDescriptor.lastMessage.id, "cmux.sidebar.last-message")
        XCTAssertEqual(CmuxExtensionSidebarProviderDescriptor.lastMessage.mode, .lastMessage)
        XCTAssertEqual(CmuxExtensionSidebarProviderDescriptor.builtInProviders.map(\.id), [
            "cmux.sidebar.default",
            "cmux.sidebar.project-tree",
            "cmux.sidebar.attention",
            "cmux.sidebar.servers",
            "cmux.sidebar.last-message",
        ])
    }

    func testProviderRenderModelAddsInspectorAccessories() {
        let first = workspace(title: "API", rootPath: "/tmp/cmux/api", projectRootPath: "/tmp/cmux")
        let second = workspace(title: "Web", rootPath: "/tmp/cmux/web", projectRootPath: "/tmp/cmux")
        let snapshot = CmuxExtensionSidebarSnapshot(
            sequence: 42,
            selectedWorkspaceId: first.id,
            workspaces: [first, second]
        )

        let model = CmuxExtensionWorkspaceTreeProvider(descriptor: .projectTree).render(snapshot: snapshot)

        XCTAssertEqual(model.providerId, CmuxExtensionSidebarProviderID.projectTree)
        XCTAssertEqual(model.snapshotSequence, 42)
        XCTAssertEqual(model.sections.map(\.treeSection.id), ["folder:/tmp/cmux"])
        XCTAssertEqual(model.sections[0].rows.map(\.workspaceId), [first.id, second.id])
        XCTAssertEqual(model.sections[0].rows.map(\.accessory?.kind), [.workspaceInspector, .workspaceInspector])
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

    func testLegacyPullRequestTabDecodesAsBrowser() throws {
        let data = try JSONEncoder().encode("pullRequest")
        let decoded = try JSONDecoder().decode(CmuxExtensionWorkspacePopoverTab.self, from: data)

        XCTAssertEqual(decoded, .browser)
    }

    func testLastMessageProviderSortsBySubmittedTimeAndAddsRelativeRows() {
        let olderDate = Date(timeIntervalSinceReferenceDate: 100)
        let newerDate = Date(timeIntervalSinceReferenceDate: 200)
        let older = workspace(
            title: "Older",
            rootPath: "/tmp/cmux/older",
            projectRootPath: "/tmp/cmux",
            latestSubmittedMessage: "review the tests",
            latestSubmittedAt: olderDate
        )
        let newer = workspace(
            title: "Newer",
            rootPath: "/tmp/cmux/newer",
            projectRootPath: "/tmp/cmux",
            latestSubmittedMessage: "ship the sidebar",
            latestSubmittedAt: newerDate
        )
        let empty = workspace(title: "Empty", rootPath: "/tmp/cmux/empty", projectRootPath: "/tmp/cmux")
        let snapshot = CmuxExtensionSidebarSnapshot(
            sequence: 9,
            selectedWorkspaceId: nil,
            workspaces: [older, empty, newer]
        )

        let model = CmuxExtensionWorkspaceTreeProvider(descriptor: .lastMessage).render(
            snapshot: snapshot,
            context: CmuxExtensionSidebarRenderContext(now: Date(timeIntervalSinceReferenceDate: 250))
        )

        XCTAssertEqual(model.providerId, CmuxExtensionSidebarProviderID.lastMessage)
        XCTAssertEqual(model.sections.map(\.id), ["last-message:recent", "last-message:none"])
        XCTAssertEqual(model.sections[0].rows.map(\.workspaceId), [newer.id, older.id])
        XCTAssertEqual(model.sections[0].rows[0].subtitle, .plain("ship the sidebar"))
        XCTAssertEqual(model.sections[0].rows[0].trailingText, .relativeDate(newerDate, style: .compact))
        XCTAssertEqual(model.sections[1].rows.map(\.workspaceId), [empty.id])
        XCTAssertEqual(
            model.sections[1].rows[0].subtitle,
            .localized(.init(key: "sidebar.custom.lastMessage.none", defaultValue: "No messages yet"))
        )
        XCTAssertNil(model.sections[1].rows[0].trailingText)
        XCTAssertEqual(model.relativeTextDates, [newerDate, olderDate])
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
