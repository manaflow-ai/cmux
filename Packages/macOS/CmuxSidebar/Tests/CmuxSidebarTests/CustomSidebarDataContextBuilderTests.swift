import CmuxSwiftRender
import Foundation
import Testing

@testable import CmuxSidebar

@Suite("CustomSidebarDataContextBuilder")
struct CustomSidebarDataContextBuilderTests {
    private func fixedCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func minimalSurface(id: UUID = UUID()) -> CustomSidebarSurfaceSnapshot {
        CustomSidebarSurfaceSnapshot(
            panelId: id,
            title: "shell",
            isFocused: false,
            isPinned: false,
            directory: nil,
            gitBranch: nil,
            gitIsDirty: false,
            listeningPorts: []
        )
    }

    private func minimalWorkspace(
        id: UUID = UUID(),
        index: Int = 0,
        surfaces: [CustomSidebarSurfaceSnapshot] = []
    ) -> CustomSidebarWorkspaceSnapshot {
        CustomSidebarWorkspaceSnapshot(
            id: id,
            title: "Workspace",
            isSelected: false,
            isPinned: false,
            index: index,
            directory: "/repo",
            listeningPorts: [],
            unreadCount: 0,
            surfaces: surfaces,
            surfaceCount: surfaces.count,
            customDescription: nil,
            customColor: nil,
            gitBranch: nil,
            gitIsDirty: false,
            pullRequestValues: [],
            progress: nil,
            latestConversationMessage: nil,
            latestSubmittedMessage: nil,
            latestSubmittedAt: nil,
            remote: nil
        )
    }

    @Test("Always-present top-level keys are produced")
    func topLevelKeys() {
        let builder = CustomSidebarDataContextBuilder(calendar: fixedCalendar())
        let selectedId = UUID()
        let snapshot = CustomSidebarContextSnapshot(
            workspaces: [minimalWorkspace(id: selectedId)],
            selectedWorkspaceId: selectedId,
            selectedWorkspaceTitle: "Picked",
            totalUnreadCount: 7,
            now: Date(timeIntervalSince1970: 0)
        )

        let context = builder.dataContext(for: snapshot)

        #expect(context["workspaceCount"] == .int(1))
        #expect(context["selectedTitle"] == .string("Picked"))
        #expect(context["selectedId"] == .string(selectedId.uuidString))
        #expect(context["unreadTotal"] == .int(7))
        #expect(context["workspaces"]?.iterationValues?.count == 1)
        #expect(context["clock"]?.member("epoch") == .int(0))
    }

    @Test("Empty selection yields empty selectedId string")
    func emptySelection() {
        let builder = CustomSidebarDataContextBuilder(calendar: fixedCalendar())
        let snapshot = CustomSidebarContextSnapshot(
            workspaces: [],
            selectedWorkspaceId: nil,
            selectedWorkspaceTitle: "",
            totalUnreadCount: 0,
            now: Date(timeIntervalSince1970: 0)
        )

        let context = builder.dataContext(for: snapshot)

        #expect(context["selectedId"] == .string(""))
        #expect(context["workspaceCount"] == .int(0))
    }

    @Test("Clock components derive from the injected calendar")
    func clockComponents() {
        let builder = CustomSidebarDataContextBuilder(calendar: fixedCalendar())
        // 1970-01-01 01:02:03 UTC, a Thursday (gregorian weekday 5).
        let instant = Date(timeIntervalSince1970: 3723)
        let snapshot = CustomSidebarContextSnapshot(
            workspaces: [],
            selectedWorkspaceId: nil,
            selectedWorkspaceTitle: "",
            totalUnreadCount: 0,
            now: instant
        )

        let clock = builder.dataContext(for: snapshot)["clock"]

        #expect(clock?.member("hour") == .int(1))
        #expect(clock?.member("minute") == .int(2))
        #expect(clock?.member("second") == .int(3))
        #expect(clock?.member("time") == .string("01:02:03"))
        #expect(clock?.member("weekday") == .int(5))
        #expect(clock?.member("epoch") == .int(3723))
    }

    @Test("Workspace always-present fields map straight through")
    func workspaceAlwaysPresentFields() {
        let builder = CustomSidebarDataContextBuilder()
        let id = UUID()
        var workspace = minimalWorkspace(id: id, index: 3)
        workspace = CustomSidebarWorkspaceSnapshot(
            id: id,
            title: "Title",
            isSelected: true,
            isPinned: true,
            index: 3,
            directory: "/work",
            listeningPorts: [3000, 8080],
            unreadCount: 2,
            surfaces: [minimalSurface()],
            surfaceCount: 1,
            customDescription: nil,
            customColor: nil,
            gitBranch: nil,
            gitIsDirty: false,
            pullRequestValues: [],
            progress: nil,
            latestConversationMessage: nil,
            latestSubmittedMessage: nil,
            latestSubmittedAt: nil,
            remote: nil
        )

        let value = builder.workspaceValue(workspace)

        #expect(value.member("id") == .string(id.uuidString))
        #expect(value.member("title") == .string("Title"))
        #expect(value.member("selected") == .bool(true))
        #expect(value.member("pinned") == .bool(true))
        #expect(value.member("index") == .int(3))
        #expect(value.member("directory") == .string("/work"))
        #expect(value.member("ports") == .array([.int(3000), .int(8080)]))
        #expect(value.member("portCount") == .int(2))
        #expect(value.member("unread") == .int(2))
        #expect(value.member("tabCount") == .int(1))
        // Optional fields absent when their source is nil/empty.
        #expect(value.member("description") == nil)
        #expect(value.member("color") == nil)
        #expect(value.member("branch") == nil)
        #expect(value.member("pr") == nil)
        #expect(value.member("progress") == nil)
        #expect(value.member("remote") == nil)
    }

    @Test("Empty optional strings are omitted like nil")
    func emptyOptionalStringsOmitted() {
        let builder = CustomSidebarDataContextBuilder()
        let workspace = CustomSidebarWorkspaceSnapshot(
            id: UUID(),
            title: "W",
            isSelected: false,
            isPinned: false,
            index: 0,
            directory: "/",
            listeningPorts: [],
            unreadCount: 0,
            surfaces: [],
            surfaceCount: 0,
            customDescription: "",
            customColor: "",
            gitBranch: nil,
            gitIsDirty: false,
            pullRequestValues: [],
            progress: nil,
            latestConversationMessage: "",
            latestSubmittedMessage: "",
            latestSubmittedAt: nil,
            remote: nil
        )

        let value = builder.workspaceValue(workspace)

        #expect(value.member("description") == nil)
        #expect(value.member("color") == nil)
        #expect(value.member("latestMessage") == nil)
        #expect(value.member("latestPrompt") == nil)
    }

    @Test("Optional workspace fields appear when present")
    func workspaceOptionalFields() {
        let builder = CustomSidebarDataContextBuilder()
        let prValue: SwiftValue = .object(["number": .int(42)])
        let workspace = CustomSidebarWorkspaceSnapshot(
            id: UUID(),
            title: "W",
            isSelected: false,
            isPinned: false,
            index: 0,
            directory: "/",
            listeningPorts: [],
            unreadCount: 0,
            surfaces: [],
            surfaceCount: 0,
            customDescription: "desc",
            customColor: "#fff",
            gitBranch: "main",
            gitIsDirty: true,
            pullRequestValues: [prValue],
            progress: .init(value: 0.5, label: "building"),
            latestConversationMessage: "hi",
            latestSubmittedMessage: "do it",
            latestSubmittedAt: Date(timeIntervalSince1970: 100),
            remote: .init(target: "host", stateRawValue: "connected", isConnected: true)
        )

        let value = builder.workspaceValue(workspace)

        #expect(value.member("description") == .string("desc"))
        #expect(value.member("color") == .string("#fff"))
        #expect(value.member("branch") == .string("main"))
        #expect(value.member("dirty") == .bool(true))
        #expect(value.member("pr") == prValue)
        #expect(value.member("prs") == .array([prValue]))
        #expect(value.member("progress")?.member("value") == .double(0.5))
        #expect(value.member("progress")?.member("label") == .string("building"))
        #expect(value.member("latestMessage") == .string("hi"))
        #expect(value.member("latestPrompt") == .string("do it"))
        #expect(value.member("latestAt") == .int(100))
        #expect(value.member("remote")?.member("target") == .string("host"))
        #expect(value.member("remote")?.member("state") == .string("connected"))
        #expect(value.member("remote")?.member("connected") == .bool(true))
    }

    @Test("Progress without a label omits the label key")
    func progressWithoutLabel() {
        let builder = CustomSidebarDataContextBuilder()
        var workspace = minimalWorkspace()
        workspace = CustomSidebarWorkspaceSnapshot(
            id: workspace.id,
            title: workspace.title,
            isSelected: false,
            isPinned: false,
            index: 0,
            directory: workspace.directory,
            listeningPorts: [],
            unreadCount: 0,
            surfaces: [],
            surfaceCount: 0,
            customDescription: nil,
            customColor: nil,
            gitBranch: nil,
            gitIsDirty: false,
            pullRequestValues: [],
            progress: .init(value: 0.25, label: nil),
            latestConversationMessage: nil,
            latestSubmittedMessage: nil,
            latestSubmittedAt: nil,
            remote: nil
        )

        let progress = builder.workspaceValue(workspace).member("progress")

        #expect(progress?.member("value") == .double(0.25))
        #expect(progress?.member("label") == nil)
    }

    @Test("Surface enrichment fields appear only when present")
    func surfaceFields() {
        let builder = CustomSidebarDataContextBuilder()
        let id = UUID()
        let enriched = CustomSidebarSurfaceSnapshot(
            panelId: id,
            title: "editor",
            isFocused: true,
            isPinned: true,
            directory: "/src",
            gitBranch: "feat",
            gitIsDirty: false,
            listeningPorts: [5173]
        )

        let value = builder.surfaceValue(enriched)

        #expect(value.member("id") == .string(id.uuidString))
        #expect(value.member("title") == .string("editor"))
        #expect(value.member("focused") == .bool(true))
        #expect(value.member("pinned") == .bool(true))
        #expect(value.member("directory") == .string("/src"))
        #expect(value.member("branch") == .string("feat"))
        #expect(value.member("dirty") == .bool(false))
        #expect(value.member("ports") == .array([.int(5173)]))

        let bare = builder.surfaceValue(minimalSurface(id: id))
        #expect(bare.member("directory") == nil)
        #expect(bare.member("branch") == nil)
        #expect(bare.member("ports") == nil)
    }

    private func agent(
        id: String? = nil,
        cwd: String = "/repo",
        kind: String = "background",
        name: String? = nil,
        state: String? = nil,
        status: String? = nil,
        pid: Int? = nil,
        startedAt: Int? = nil,
        waitingFor: String? = nil
    ) -> CustomSidebarAgentSnapshot {
        CustomSidebarAgentSnapshot(
            id: id,
            cwd: cwd,
            kind: kind,
            name: name,
            sessionId: nil,
            state: state,
            status: status,
            pid: pid,
            startedAt: startedAt,
            waitingFor: waitingFor
        )
    }

    @Test("Agents array and counts are produced")
    func agentsTopLevel() {
        let builder = CustomSidebarDataContextBuilder(calendar: fixedCalendar())
        let snapshot = CustomSidebarContextSnapshot(
            workspaces: [],
            selectedWorkspaceId: nil,
            selectedWorkspaceTitle: "",
            totalUnreadCount: 0,
            agents: [
                agent(state: "working"),
                agent(state: "blocked"),
                agent(state: "done"),
            ],
            now: Date(timeIntervalSince1970: 0)
        )

        let context = builder.dataContext(for: snapshot)

        #expect(context["agentsCount"] == .int(3))
        #expect(context["agentsWorkingCount"] == .int(1))
        #expect(context["agentsBlockedCount"] == .int(1))
        #expect(context["agents"]?.iterationValues?.count == 3)
    }

    @Test("Agents default to an empty array when none are provided")
    func agentsDefaultEmpty() {
        let builder = CustomSidebarDataContextBuilder(calendar: fixedCalendar())
        let snapshot = CustomSidebarContextSnapshot(
            workspaces: [],
            selectedWorkspaceId: nil,
            selectedWorkspaceTitle: "",
            totalUnreadCount: 0,
            now: Date(timeIntervalSince1970: 0)
        )

        let context = builder.dataContext(for: snapshot)

        #expect(context["agentsCount"] == .int(0))
        #expect(context["agents"] == .array([]))
    }

    @Test("Agent value maps fields and derives state booleans")
    func agentValueMapsFields() {
        let builder = CustomSidebarDataContextBuilder(calendar: fixedCalendar())

        let blocked = builder.agentValue(
            agent(
                id: "abc123",
                cwd: "/repo/.claude/worktrees/x",
                kind: "background",
                name: "migrate config",
                state: "blocked",
                status: "waiting",
                pid: 4242,
                startedAt: 1_781_774_127_358,
                waitingFor: "permission prompt"
            )
        )
        #expect(blocked.member("cwd") == .string("/repo/.claude/worktrees/x"))
        #expect(blocked.member("kind") == .string("background"))
        #expect(blocked.member("background") == .bool(true))
        #expect(blocked.member("id") == .string("abc123"))
        #expect(blocked.member("name") == .string("migrate config"))
        #expect(blocked.member("state") == .string("blocked"))
        #expect(blocked.member("status") == .string("waiting"))
        #expect(blocked.member("pid") == .int(4242))
        #expect(blocked.member("startedAt") == .int(1_781_774_127_358))
        #expect(blocked.member("waitingFor") == .string("permission prompt"))
        #expect(blocked.member("blocked") == .bool(true))
        #expect(blocked.member("active") == .bool(true))
        #expect(blocked.member("working") == .bool(false))
        #expect(blocked.member("done") == .bool(false))

        // Optional fields are omitted; derived booleans stay present.
        let minimal = builder.agentValue(agent(cwd: "/repo", kind: "interactive", status: "idle"))
        #expect(minimal.member("id") == nil)
        #expect(minimal.member("name") == nil)
        #expect(minimal.member("state") == nil)
        #expect(minimal.member("pid") == nil)
        #expect(minimal.member("background") == .bool(false))
        #expect(minimal.member("active") == .bool(false))
        #expect(minimal.member("status") == .string("idle"))
    }
}
