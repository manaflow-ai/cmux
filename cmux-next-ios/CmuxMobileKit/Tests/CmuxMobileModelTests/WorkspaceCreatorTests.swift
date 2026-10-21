import Foundation
import Testing
@testable import CmuxMobileModel

/// A backend whose creations finish when the test says so.
@MainActor
final class ScriptedBackend: WorkspaceCreationBackend {
    var creatable: Set<String> = ["mac-studio", "mbp"]
    var options = WorkspaceCreationOptions.basic
    var requests: [NewWorkspaceRequest] = []
    /// The result for the next creation: a real workspace or a refusal.
    var result: (Workspace) -> Result<Workspace, WorkspaceCreationError> = { .success($0) }
    private var gate: CheckedContinuation<Void, Never>?
    var holds = false

    func canCreate(on macID: String) -> Bool { creatable.contains(macID) }
    func options(on macID: String) -> WorkspaceCreationOptions { options }

    func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace {
        requests.append(request)
        if holds { await withCheckedContinuation { gate = $0 } }
        return try result(placeholder).get()
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

@MainActor @Suite struct WorkspaceCreatorTests {
    let defaults: UserDefaults
    let suite = "cmuxMobile.tests.create.\(UUID().uuidString)"

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func make(_ backend: ScriptedBackend = ScriptedBackend()) -> (AppStore, WorkspaceCreator, ScriptedBackend) {
        let store = AppStore.mock(tabMemory: .inMemory())
        return (store, WorkspaceCreator(store: store, backend: backend, defaults: defaults), backend)
    }

    /// Round 2: a workspace made from the list opened with the keyboard down.
    @Test func aCreatedWorkspaceOpensReadyToType() async throws {
        let (store, creator, _) = make()
        let placeholder = try #require(creator.create())
        #expect(store.takeFocusOnOpen(placeholder.id))
        #expect(!store.takeFocusOnOpen(placeholder.id))
        // Opening an existing workspace does not raise the keyboard.
        #expect(!store.takeFocusOnOpen("ws-cmux"))
    }

    @Test func tapInsertsAPendingRowAndSettlesToTheSameWorkspace() async throws {
        let (store, creator, backend) = make()
        backend.holds = true
        let before = store.workspaces.count
        let placeholder = try #require(creator.create())
        // Instant: the row is in the list and pending before the Mac answers.
        #expect(store.workspaces.count == before + 1)
        #expect(store.isPending(placeholder.id))
        #expect(creator.phases[placeholder.id] == .pending)
        #expect(placeholder.macID == "mac-studio")
        #expect(placeholder.tabs.map(\.kind) == [.terminal])
        #expect(placeholder.title == "New Workspace")
        while backend.requests.isEmpty { await Task.yield() }
        backend.release()
        await creator.settle()
        #expect(!store.isPending(placeholder.id))
        #expect(creator.phases[placeholder.id] == .created(placeholder.id))
        #expect(store.workspace(id: placeholder.id) != nil)
    }

    @Test func aRealWorkspaceWithItsOwnIdReplacesThePlaceholder() async throws {
        let (store, creator, backend) = make()
        let real = Workspace(id: "w42", macID: "mac-studio", title: "New Workspace", directory: "~",
                             tabs: [WorkspaceTab(id: "s7", kind: .terminal, title: "zsh"),
                                    WorkspaceTab(id: "s8", kind: .browser, title: "Browser")],
                             lastActivityAt: Date())
        backend.options = WorkspaceCreationOptions(browser: true)
        backend.result = { _ in .success(real) }
        let placeholder = try #require(creator.create(start: .browser))
        await creator.settle()
        #expect(store.workspaces.contains { $0.id == "w42" })
        #expect(!store.workspaces.contains { $0.id == placeholder.id })
        // The screen opened on the placeholder follows the real workspace, on the browser tab.
        #expect(store.workspace(id: placeholder.id)?.id == "w42")
        #expect(store.openingTab(for: real)?.id == "s8")
        #expect(creator.phases[placeholder.id] == .created("w42"))
    }

    @Test func aTreeRefreshKeepsThePendingRowAndDoesNotDuplicateTheRealOne() async throws {
        let (store, creator, backend) = make()
        backend.holds = true
        let real = Workspace(id: "w9", macID: "mac-studio", title: "New Workspace", directory: "~",
                             tabs: [WorkspaceTab(id: "s1", kind: .terminal, title: "zsh")], lastActivityAt: Date())
        backend.result = { _ in .success(real) }
        let placeholder = try #require(creator.create())
        while backend.requests.isEmpty { await Task.yield() }
        // The daemon's tree arrives before the reply.
        store.replaceWorkspaces(macID: "mac-studio", with: [real])
        #expect(store.workspaces.contains { $0.id == placeholder.id })
        backend.release()
        await creator.settle()
        #expect(store.workspaces.filter { $0.id == "w9" }.count == 1)
        #expect(!store.workspaces.contains { $0.id == placeholder.id })
    }

    @Test func aRefusalRemovesTheRowAndReportsIt() async throws {
        let (store, creator, backend) = make()
        backend.result = { _ in .failure(WorkspaceCreationError("new-workspace is not available to a phone")) }
        var reported: (Workspace, String)?
        creator.onFailure = { reported = ($0, $1) }
        let before = store.workspaces.map(\.id)
        let placeholder = try #require(creator.create())
        await creator.settle()
        #expect(store.workspaces.map(\.id) == before)
        #expect(!store.isPending(placeholder.id))
        #expect(creator.phases[placeholder.id] == .failed("new-workspace is not available to a phone"))
        #expect(reported?.0.id == placeholder.id)
        #expect(reported?.1 == "new-workspace is not available to a phone")
    }

    @Test func noMacNoWorkspace() {
        let (store, creator, backend) = make()
        backend.creatable = []
        let before = store.workspaces.count
        #expect(creator.create() == nil)
        #expect(store.workspaces.count == before)
    }

    @Test func thePreferredMacWinsWhenAvailable() throws {
        let (store, creator, backend) = make()
        #expect(creator.targetMac?.id == "mac-studio")
        // Wake the MacBook Pro so two Macs can take a workspace.
        var macs = try #require(store.activeTeam?.macs)
        macs[1].isOnline = true
        store.setMacs(macs, teamID: store.activeTeamID)
        creator.prefer(macID: "mbp")
        #expect(try #require(creator.create()).macID == "mbp")
        backend.creatable = ["mac-studio"]
        #expect(creator.targetMac?.id == "mac-studio")
    }

    @Test func unsupportedStartsAreRefusedUpFront() {
        let (_, creator, _) = make()
        #expect(creator.create(start: .agent("claude")) == nil)
        #expect(creator.create(start: .browser) == nil)
    }

    @Test func directoriesOnlyWhenTheBackendCanChooseThem() async throws {
        let (store, creator, backend) = make()
        // The daemon picks the directory: no recents, and the request carries none.
        #expect(creator.recentDirectories(on: "mac-studio").isEmpty)
        _ = try #require(creator.create())
        await creator.settle()
        #expect(backend.requests.last?.directory == nil)

        backend.options = WorkspaceCreationOptions(directories: true, agents: ["claude"])
        // Default: home, then the last directory used on that Mac.
        #expect(creator.defaultDirectory(on: "mac-studio") == "~")
        let first = try #require(creator.create(start: .agent("claude"), directory: "~/Development/cmux"))
        #expect(first.title == "cmux 2")
        #expect(first.tabs.first?.harness == "claude")
        await creator.settle()
        #expect(creator.defaultDirectory(on: "mac-studio") == "~/Development/cmux")
        let recents = creator.recentDirectories(on: "mac-studio")
        #expect(recents.first == "~/Development/cmux")
        #expect(recents.contains("~/Development/web"))
        #expect(Set(recents).count == recents.count)
        #expect(store.workspaces.filter { ["cmux", "cmux 2"].contains($0.title) }.count == 2)
    }

    @Test func uniqueTitles() {
        #expect(WorkspaceCreator.uniqueTitle("New Workspace", existing: []) == "New Workspace")
        #expect(WorkspaceCreator.uniqueTitle("New Workspace", existing: ["New Workspace", "New Workspace 2"]) == "New Workspace 3")
        #expect(WorkspaceCreator.title(for: "~") == "New Workspace")
        #expect(WorkspaceCreator.title(for: "~/notes") == "notes")
    }

    @Test func mockBackendSucceedsThenFailsOnRequest() async throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let mock = MockWorkspaceCreationBackend(latency: .zero)
        let creator = WorkspaceCreator(store: store, backend: mock, defaults: defaults)
        let ok = try #require(creator.create(start: .agent("codex")))
        await creator.settle()
        #expect(creator.phases[ok.id] == .created(ok.id))
        mock.failNext = "cmux mini 2 is busy"
        let bad = try #require(creator.create(start: .browser))
        await creator.settle()
        #expect(creator.phases[bad.id] == .failed("cmux mini 2 is busy"))
        #expect(store.workspace(id: bad.id) == nil)
    }
}
