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
        // The tab is the agent, as the Mac's tab reads once listed (live run 3: the pill flipped
        // from the task to the agent's name); the workspace carries the task.
        #expect(placeholder.tabs.first?.title == "Claude")
        #expect(placeholder.tabs.first?.subtitle == nil)
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
        // The agent first: rows of one task differ only by it, and a long task title truncates.
        #expect(made.map(\.title) == ["Claude · Write the release notes", "Claude Code Router · Write the release notes"])
        #expect(made.allSatisfy { !store.takeFocusOnOpen($0.id) })
        await creator.settle()
        #expect(backend.requests.map(\.start) == [.agent("claude"), .agent("claude-cr")])
        #expect(backend.requests.map { $0.task?.model } == [nil, "kimi-k2"])
        #expect(Set(backend.requests.map(\.directory)).count == 1)
    }

    @Test func aRefusedTaskGivesItsDraftBackOnceUnlessANewOneWasStarted() async throws {
        let (store, creator, backend) = make()
        backend.result = { _ in .failure(WorkspaceCreationError("Trust web on the Mac first.", isForPerson: true)) }
        var failures: [String] = []
        creator.onFailure = { _, message in failures.append(message) }
        let draft = TaskDraft(prompt: "Try this", picks: [TaskAgentPick(harness: "claude"), TaskAgentPick(harness: "claude-cr")])
        let made = creator.startTask(draft)
        await creator.settle()
        #expect(made.allSatisfy { store.workspace(id: $0.id) == nil })
        #expect(failures == ["Trust web on the Mac first.", "Trust web on the Mac first."])
        #expect(creator.taskDraft == draft)
        // The composer says why, and the toast that the draft is back.
        #expect(creator.taskRefusal == "Trust web on the Mac first.")
        #expect(made.allSatisfy { creator.wasRefusedTask($0.id) })

        // A draft written meanwhile is never replaced: the refused task goes to Drafts, both
        // of its agents in one draft.
        let again = creator.startTask(TaskDraft(prompt: "Try again", picks: draft.picks))
        #expect(creator.taskRefusal == nil)
        creator.taskDraft.prompt = "Something else"
        await creator.settle()
        #expect(creator.taskDraft.prompt == "Something else")
        #expect(creator.taskRefusal == nil)
        #expect(again.allSatisfy { creator.refusedTaskPlace($0.id) == .drafts })
        let saved = try #require(creator.taskDrafts.drafts.first)
        #expect(creator.taskDrafts.drafts.count == 1 && saved.prompt == "Try again")
        #expect(saved.picks.map(\.harness) == ["claude", "claude-cr"])
    }

    /// Review 2026-11-12: one refused agent of several brings back only that agent, so the
    /// next Start doesn't run the task again on the agent that already has it.
    @Test func onlyTheRefusedAgentComesBack() async throws {
        let (_, creator, backend) = make()
        backend.result = { placeholder in
            placeholder.title.hasPrefix("Claude Code Router") ? .failure(WorkspaceCreationError("Router is down", isForPerson: true)) : .success(placeholder)
        }
        let claude = TaskAgentPick(harness: "claude", name: "Claude Code")
        let router = TaskAgentPick(harness: "claude-cr", name: "Claude Code Router")
        let made = creator.startTask(TaskDraft(prompt: "Ship it", picks: [claude, router]))
        await creator.settle()
        #expect(creator.taskDraft.prompt == "Ship it")
        #expect(creator.taskDraft.picks == [router])
        #expect(creator.taskRefusal == "Router is down")
        #expect(creator.wasRefusedTask(made[1].id) && !creator.wasRefusedTask(made[0].id))
    }

    /// Live run 2026-11-12: an agent's start refusal not written for the person ("Authentication
    /// required") still reaches the composer, as the Mac's words, not a generic line.
    @Test func aRefusalNotWrittenForThePersonIsQuotedAsTheMacs() async throws {
        let (_, creator, backend) = make()
        backend.result = { _ in .failure(WorkspaceCreationError("Authentication required")) }
        creator.startTask(TaskDraft(prompt: "Go", picks: [TaskAgentPick(harness: "claude")]))
        await creator.settle()
        #expect(creator.taskRefusal == "The Mac said: Authentication required")
    }

    /// A refusal over a new task being written leaves that task alone and saves the refused one
    /// in Drafts (the toast says so).
    @Test func aRefusalOverANewDraftGoesToDrafts() async throws {
        let (_, creator, backend) = make()
        backend.result = { _ in .failure(WorkspaceCreationError("No")) }
        // The Mac answers only at `settle`: the person starts writing the next task first.
        let made = creator.startTask(TaskDraft(prompt: "First"))
        creator.taskDraft.prompt = "Second"
        await creator.settle()
        #expect(creator.taskDraft.prompt == "Second")
        #expect(creator.refusedTaskPlace(made[0].id) == .drafts)
        #expect(creator.taskRefusal == nil)
        #expect(creator.taskDrafts.drafts.map(\.prompt) == ["First"])
    }

    /// Review 2026-11-12: the task goes to the chat once the workspace exists, and a failure
    /// to deliver it is reported against that workspace, never handed back as a draft (the
    /// agent may have it, and a second Start would run it twice).
    @Test func theTaskIsSentAfterTheWorkspaceExistsAndAFailureNeverRestoresTheDraft() async throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let mock = MockWorkspaceCreationBackend(latency: .zero)
        let creator = WorkspaceCreator(store: store, backend: mock, defaults: defaults)
        var reports: [TaskDeliveryFailure] = []
        creator.onTaskNotDelivered = { _, _, failure in reports.append(failure) }
        let made = creator.startTask(TaskDraft(prompt: "Go", picks: [TaskAgentPick(harness: "claude", model: "opus")]))
        #expect(mock.sentTasks.isEmpty)
        await creator.settle()
        #expect(mock.sentTasks == [AgentTask(prompt: "Go", model: "opus")])
        #expect(reports.isEmpty)

        mock.taskFailure = .uncertain("The connection dropped")
        creator.startTask(TaskDraft(prompt: "Again"))
        await creator.settle()
        #expect(reports == [.uncertain("The connection dropped")])
        #expect(creator.taskDraft.prompt.isEmpty)
        #expect(creator.taskRefusal == nil)
        #expect(store.workspace(id: made[0].id) != nil)
    }

    /// A3: a task takes at most four agents, always keeps one, and never an agent a phone can't start;
    /// with no pick, the agent shown checked becomes the first real pick.
    @Test func pickingAgentsKeepsOneAndStopsAtTheLimit() {
        func agent(_ id: String, start: Bool = true) -> AgentHarnessChoice {
            AgentHarnessChoice(id: id, name: id.capitalized, family: "claude", unavailableReason: start ? nil : "No")
        }
        var draft = TaskDraft(prompt: "go")
        #expect(draft.toggle(agent("b"), fallback: agent("a")) == .added)
        #expect(draft.picks.map(\.harness) == ["a", "b"])
        #expect(draft.toggle(agent("a"), fallback: nil) == .removed)
        #expect(draft.toggle(agent("b"), fallback: nil) == .keptLast)
        #expect(draft.picks.map(\.harness) == ["b"])
        for id in ["c", "d", "e"] { #expect(draft.toggle(agent(id), fallback: nil) == .added) }
        #expect(draft.toggle(agent("f"), fallback: nil) == .atLimit)
        #expect(draft.picks.count == TaskDraft.agentLimit)
        #expect(draft.toggle(agent("x", start: false), fallback: nil) == .unavailable)
    }

    /// A4: another Mac has its own agents, so its picks start over; the same Mac keeps them.
    @Test func choosingAnotherMacClearsThePicks() {
        var draft = TaskDraft(prompt: "go", picks: [TaskAgentPick(harness: "claude")], macID: "mac-studio")
        draft.chooseMac("mac-studio")
        #expect(draft.picks.count == 1)
        draft.chooseMac("mbp")
        #expect(draft.picks.isEmpty && draft.macID == "mbp")
    }

    /// A8: Start clears what the task said (prompt, photos, name) and keeps its agents, Mac and folder.
    @Test func startClearsTheNameToo() async throws {
        let (_, creator, _) = make()
        let draft = TaskDraft(prompt: "go", picks: [TaskAgentPick(harness: "claude")], directory: "~/Development/web", name: "web fix")
        creator.taskDraft = draft
        creator.startTask(draft)
        #expect(creator.taskDraft.name.isEmpty && creator.taskDraft.prompt.isEmpty)
        #expect(creator.taskDraft.directory == "~/Development/web" && creator.taskDraft.picks == draft.picks)
        await creator.settle()
    }

    @Test func imageTypeIsReadFromItsBytes() {
        #expect(TaskImage(data: Data([0xFF, 0xD8, 0xFF] + Array(repeating: 0, count: 9))).mimeType == "image/jpeg")
        #expect(TaskImage(data: Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8))).mimeType == "image/webp")
        #expect(TaskImage(data: Data(Array("ftypheic0000".utf8))).mimeType == nil)
    }
}

/// The workspace page finds a creating workspace's opening tab by this id (WorkspaceTabsSource.placeholderTabID).
@MainActor @Suite struct PlaceholderTabIDTests {
    @Test func theOpeningTabIsTheWorkspaceIDAndT1() {
        let ws = WorkspaceCreator.placeholder(for: NewWorkspaceRequest(macID: "m", start: .agent("")), existing: [])
        #expect(ws.tabs.first?.id == "\(ws.id)-t1")
    }
}


/// Drafts (classic's): leaving New Task with a task saves it, the list resumes or deletes it,
/// and Start takes it off the list.
@MainActor @Suite struct TaskDraftsTests {
    let defaults: UserDefaults
    init() throws { defaults = try #require(UserDefaults(suiteName: "cmuxMobile.tests.drafts.\(UUID().uuidString)")) }

    func make(store drafts: TaskDraftStore = TaskDraftStore(directory: nil)) -> WorkspaceCreator {
        let backend = ScriptedBackend()
        backend.creatable = ["mac-studio"]
        backend.options = WorkspaceCreationOptions(directories: true, agents: [""], browser: true)
        return WorkspaceCreator(store: AppStore.mock(tabMemory: .inMemory()), backend: backend, defaults: defaults, taskDrafts: drafts)
    }

    static func png(_ byte: UInt8) -> TaskImage {
        TaskImage(data: Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: byte, count: 12)))
    }

    @Test func leavingWithATaskAsksAndSaveDraftKeepsIt() {
        let creator = make()
        #expect(!creator.taskDraftNeedsSaving)
        creator.taskDraft.prompt = "Fix the login bug"
        creator.taskDraft.picks = [TaskAgentPick(harness: "claude")]
        #expect(creator.taskDraftNeedsSaving)
        let id = creator.taskDraft.id
        creator.leaveTaskComposer(keep: true)
        #expect(creator.taskDrafts.drafts.map(\.id) == [id])
        // The next task starts empty, with the same agents.
        #expect(creator.taskDraft.prompt.isEmpty && creator.taskDraft.id != id)
        #expect(creator.taskDraft.picks == [TaskAgentPick(harness: "claude")])
    }

    @Test func deleteDraftLeavesNothing() {
        let creator = make()
        creator.taskDraft.prompt = "Throwaway"
        creator.saveTaskDraft()
        creator.leaveTaskComposer(keep: false)
        #expect(creator.taskDrafts.drafts.isEmpty)
    }

    @Test func aResumedDraftLeftAsItWasAsksNothingAndAChangedOneAsks() async throws {
        let creator = make()
        creator.taskDraft.prompt = "Saved one"
        let id = creator.taskDraft.id
        creator.leaveTaskComposer(keep: true)
        #expect(await creator.resumeTaskDraft(id))
        #expect(creator.taskDraft.prompt == "Saved one" && creator.taskDraft.id == id)
        #expect(!creator.taskDraftNeedsSaving)
        creator.taskDraft.prompt = "Saved one, edited"
        #expect(creator.taskDraftNeedsSaving)
    }

    @Test func resumingSavesTheDraftHeldFirstAndTheListLeavesItOut() async throws {
        let creator = make()
        creator.taskDraft.prompt = "A"
        let a = creator.taskDraft.id
        creator.newTaskDraft()
        creator.taskDraft.prompt = "B"
        let b = creator.taskDraft.id
        #expect(creator.otherTaskDrafts.map(\.id) == [a])
        #expect(await creator.resumeTaskDraft(a))
        #expect(creator.taskDraft.prompt == "A")
        #expect(Set(creator.taskDrafts.drafts.map(\.id)) == [a, b])
        #expect(creator.otherTaskDrafts.map(\.id) == [b])
    }

    @Test func startTakesTheDraftOffTheList() async throws {
        let creator = make()
        creator.taskDraft.prompt = "Ship it"
        creator.saveTaskDraft()
        #expect(creator.taskDrafts.drafts.count == 1)
        creator.startTask(creator.taskDraft)
        #expect(creator.taskDrafts.drafts.isEmpty)
        await creator.settle()
    }

    @Test func aDraftWithPhotosResumesWithThem() async throws {
        let creator = make()
        creator.taskDraft.prompt = "Match this"
        let photos = [Self.png(1), Self.png(2)]
        creator.taskDraft.images = photos
        let id = creator.taskDraft.id
        creator.leaveTaskComposer(keep: true)
        #expect(creator.taskDrafts.drafts.first?.imageIDs == photos.map(\.id))
        #expect(await creator.resumeTaskDraft(id))
        #expect(creator.taskDraft.images == photos)
    }

    /// On disk: a store read again (the next launch) has the drafts, photos included, newest
    /// first; a deleted draft's photos are removed.
    @Test func draftsOnDiskSurviveARelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("task-drafts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = TaskDraftStore(directory: folder)
        await first.load()
        var older = TaskDraft(prompt: "Older", images: [Self.png(7)])
        older.picks = [TaskAgentPick(harness: "claude", model: "sonnet", name: "Claude Code")]
        first.save(older, now: Date(timeIntervalSince1970: 100))
        let newer = TaskDraft(prompt: "Newer", directory: "~/Development/web")
        first.save(newer, now: Date(timeIntervalSince1970: 200))
        await first.flush()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("images").path).count == 1)

        let second = TaskDraftStore(directory: folder)
        await second.load()
        #expect(second.drafts.map(\.prompt) == ["Newer", "Older"])
        let read = try #require(await second.draft(older.id))
        #expect(read.images.map(\.data) == [Self.png(7).data])
        #expect(read.picks == older.picks && read.prompt == "Older")

        second.delete([older.id])
        await second.flush()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("images").path).isEmpty)
        let third = TaskDraftStore(directory: folder)
        await third.load()
        #expect(third.drafts.map(\.prompt) == ["Newer"])
    }

    @Test func theListKeepsTheNewestUpToItsLimit() {
        let drafts = TaskDraftStore(directory: nil)
        for index in 0..<(TaskDraftStore.limit + 3) {
            drafts.save(TaskDraft(prompt: "Task \(index)"), now: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(drafts.drafts.count == TaskDraftStore.limit)
        #expect(drafts.drafts.first?.prompt == "Task \(TaskDraftStore.limit + 2)")
    }

    @Test func aPhotoIDIsNeverAPath() {
        #expect(TaskDraftDisk.isSafeName(UUID().uuidString))
        #expect(!TaskDraftDisk.isSafeName("../index.json"))
        #expect(!TaskDraftDisk.isSafeName("a/b"))
        #expect(!TaskDraftDisk.isSafeName(""))
    }
}
