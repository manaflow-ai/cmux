import Foundation
import Testing
@testable import CmuxMobileModel

/// New Task: the composer's draft, its Start rules and the workspaces Start makes.
@MainActor @Suite struct TaskComposerTests {
    let defaults: UserDefaults
    let suite = "cmuxMobile.tests.task.\(UUID().uuidString)"

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func make() -> (AppStore, WorkspaceCreator, ScriptedBackend) {
        let store = AppStore.mock(tabMemory: .inMemory())
        let backend = ScriptedBackend()
        backend.creatable = ["mac-studio"]
        backend.options = WorkspaceCreationOptions(directories: true, agents: [""], browser: true)
        return (store, WorkspaceCreator(store: store, backend: backend, defaults: defaults), backend)
    }

    @Test func titleIsTheNameElseThePromptsFirstLineCutAtAWord() {
        #expect(TaskDraft(prompt: "  \n").title == "New Task")
        #expect(TaskDraft(prompt: "Fix the login bug\nDetails below").title == "Fix the login bug")
        #expect(TaskDraft(prompt: "Fix it", name: " Login ").title == "Login")
        let long = TaskDraft(prompt: "Refactor the transport layer so reconnects keep their queued prompts intact")
        #expect(long.title == "Refactor the transport layer so reconnects keep…")
        #expect(long.title.count <= 49)
    }

    @Test func startIsBlockedUntilThereIsAPromptAFolderAndFewAgents() {
        let (_, creator, backend) = make()
        #expect(creator.taskBlocker(TaskDraft()) == .noPrompt)
        #expect(creator.taskBlocker(TaskDraft(prompt: "go")) == nil)
        let five = (1...5).map { TaskAgentPick(harness: "a\($0)") }
        #expect(creator.taskBlocker(TaskDraft(prompt: "go", picks: five)) == .tooManyAgents)
        // No agents connected on the only Mac: no Mac takes tasks.
        backend.options = WorkspaceCreationOptions(directories: true, agents: [], browser: true)
        #expect(creator.taskMacs.isEmpty)
        #expect(creator.taskBlocker(TaskDraft(prompt: "go")) == .noMac)
    }

    @Test func homeIsNeverATaskFolderAndANoFolderMacSaysSo() {
        let (store, creator, _) = make()
        #expect(!creator.taskFolders(on: "mac-studio").isEmpty)
        #expect(!creator.taskFolders(on: "mac-studio").contains("~"))
        // A Mac whose only workspaces sit in home has no folder for a task.
        store.workspaces = store.workspaces.map { var ws = $0; ws.directory = "~"; return ws }
        #expect(creator.taskFolders(on: "mac-studio").isEmpty)
        #expect(creator.taskBlocker(TaskDraft(prompt: "go")) == .noFolder)
    }

    @Test func startMakesOneOpenedWorkspaceWithTheTaskAndClearsThePrompt() async throws {
        let (store, creator, backend) = make()
        let image = TaskImage(data: Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: 0, count: 12)))
        let draft = TaskDraft(prompt: "  Fix the flaky upload test  ", images: [image],
                              picks: [TaskAgentPick(harness: "claude", model: "sonnet")],
                              directory: "~/Development/web")
        creator.taskDraft = draft
        let made = creator.startTask(draft)
        #expect(made.count == 1)
        let placeholder = try #require(made.first)
        // Instant: the row is in the list, titled for the task, and opens ready to type.
        #expect(store.isPending(placeholder.id))
        #expect(placeholder.title == "Fix the flaky upload test")
        #expect(placeholder.tabs.first?.task == "Fix the flaky upload test")
        #expect(placeholder.tabs.first?.agentStatus == .working)
        #expect(store.takeFocusOnOpen(placeholder.id))
        // The prompt goes; the agents and folder stay for the next task.
        #expect(creator.taskDraft.prompt.isEmpty && creator.taskDraft.images.isEmpty)
        #expect(creator.taskDraft.picks == draft.picks && creator.taskDraft.directory == draft.directory)
        await creator.settle()
        let request = try #require(backend.requests.first)
        #expect(request.start == .agent("claude"))
        #expect(request.directory == "~/Development/web")
        #expect(request.task == AgentTask(prompt: "Fix the flaky upload test", images: [image], model: "sonnet"))
        #expect(creator.phases[placeholder.id] == .created(placeholder.id))
    }

    @Test func noPickStartsTheMacsDefaultAgent() async throws {
        let (_, creator, backend) = make()
        creator.startTask(TaskDraft(prompt: "go"))
        await creator.settle()
        #expect(backend.requests.map(\.start) == [.agent("")])
    }

    @Test func severalAgentsMakeOneWorkspaceEachNoneFocused() async throws {
        let (store, creator, backend) = make()
        let draft = TaskDraft(prompt: "Write the release notes",
                              picks: [TaskAgentPick(harness: "claude"), TaskAgentPick(harness: "claude-cr", model: "kimi-k2", name: "Claude Code Router")])
        let made = creator.startTask(draft)
        #expect(made.map(\.title) == ["Write the release notes · Claude", "Write the release notes · Claude Code Router"])
        #expect(made.allSatisfy { !store.takeFocusOnOpen($0.id) })
        await creator.settle()
        #expect(backend.requests.map(\.start) == [.agent("claude"), .agent("claude-cr")])
        #expect(backend.requests.map { $0.task?.model } == [nil, "kimi-k2"])
        #expect(Set(backend.requests.map(\.directory)).count == 1)
    }

    @Test func aRefusedTaskGivesItsDraftBackOnceUnlessANewOneWasStarted() async throws {
        let (store, creator, backend) = make()
        backend.result = { _ in .failure(WorkspaceCreationError("Folder not trusted")) }
        var failures: [String] = []
        creator.onFailure = { _, message in failures.append(message) }
        let draft = TaskDraft(prompt: "Try this", picks: [TaskAgentPick(harness: "claude"), TaskAgentPick(harness: "claude-cr")])
        let made = creator.startTask(draft)
        await creator.settle()
        #expect(made.allSatisfy { store.workspace(id: $0.id) == nil })
        #expect(failures == ["Folder not trusted", "Folder not trusted"])
        #expect(creator.taskDraft == draft)

        // A draft written meanwhile is never replaced.
        creator.startTask(draft)
        creator.taskDraft.prompt = "Something else"
        await creator.settle()
        #expect(creator.taskDraft.prompt == "Something else")
    }

    @Test func imageTypeIsReadFromItsBytes() {
        #expect(TaskImage(data: Data([0xFF, 0xD8, 0xFF] + Array(repeating: 0, count: 9))).mimeType == "image/jpeg")
        #expect(TaskImage(data: Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8))).mimeType == "image/webp")
        #expect(TaskImage(data: Data(Array("ftypheic0000".utf8))).mimeType == nil)
    }
}
