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

    /// These cases are about chat launches (the first message's delivery, the chat's tab).
    static func chat(_ draft: TaskDraft) -> TaskDraft {
        var draft = draft
        draft.launch = .chat
        return draft
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
        let made = creator.startTask(Self.chat(draft))
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
        creator.startTask(Self.chat(TaskDraft(prompt: "go")))
        await creator.settle()
        #expect(backend.requests.map(\.start) == [.agent("")])
    }

    @Test func severalAgentsMakeOneWorkspaceEachNoneFocused() async throws {
        let (store, creator, backend) = make()
        let draft = TaskDraft(prompt: "Write the release notes",
                              picks: [TaskAgentPick(harness: "claude"), TaskAgentPick(harness: "claude-cr", model: "kimi-k2", name: "Claude Code Router")])
        let made = creator.startTask(Self.chat(draft))
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
        let draft = Self.chat(TaskDraft(prompt: "Try this", picks: [TaskAgentPick(harness: "claude"), TaskAgentPick(harness: "claude-cr")]))
        let made = creator.startTask(draft)
        await creator.settle()
        #expect(made.allSatisfy { store.workspace(id: $0.id) == nil })
        #expect(failures == ["Trust web on the Mac first.", "Trust web on the Mac first."])
        #expect(creator.taskDraft == draft)
        // Given back and saved at once (the app may be gone before the composer reopens).
        #expect(creator.taskDrafts.entry(draft.id)?.prompt == "Try this")
        // The composer says why, and the toast that the draft is back.
        #expect(creator.taskRefusal == "Trust web on the Mac first.")
        #expect(made.allSatisfy { creator.wasRefusedTask($0.id) })

        // A draft written meanwhile is never replaced: the refused task goes to Drafts, both
        // of its agents in one draft.
        let again = creator.startTask(Self.chat(TaskDraft(prompt: "Try again", picks: draft.picks)))
        #expect(creator.taskRefusal == nil)
        creator.taskDraft.prompt = "Something else"
        await creator.settle()
        #expect(creator.taskDraft.prompt == "Something else")
        #expect(creator.taskRefusal == nil)
        #expect(again.allSatisfy { creator.refusedTaskPlace($0.id) == .drafts })
        // The first refusal was saved to Drafts too (review 2026-11-14), so both refused tasks
        // are kept; the newest is the one refused over the task being written.
        let saved = try #require(creator.taskDrafts.drafts.first)
        #expect(saved.prompt == "Try again")
        #expect(saved.picks.map(\.harness) == ["claude", "claude-cr"])
        #expect(Set(creator.taskDrafts.drafts.map(\.prompt)) == ["Try this", "Try again"])
    }

    /// Review 2026-11-14 (high): a terminal task whose command was typed, or may have been, is
    /// never handed back, whatever fails after: a second Start would run it twice.
    @Test func aTerminalTaskThatMayHaveStartedIsNeverHandedBack() async throws {
        let (_, creator, backend) = make()
        backend.result = { _ in
            .failure(WorkspaceCreationError("The task started on the Mac, but its workspace didn't show here.", isForPerson: true,
                                            mayHaveStarted: true))
        }
        var failures: [String] = []
        creator.onFailure = { _, message in failures.append(message) }
        let made = creator.startTask(TaskDraft(prompt: "Run the migrations", picks: [TaskAgentPick(harness: "claude")], launch: .terminal))
        await creator.settle()
        #expect(failures.count == 1)
        #expect(creator.taskDraft.prompt.isEmpty && creator.taskRefusal == nil)
        #expect(creator.taskDrafts.drafts.isEmpty)
        #expect(creator.refusedTaskPlace(made[0].id) == .mayHaveStarted)
        #expect(!creator.wasRefusedTask(made[0].id))
    }

    /// Review 2026-11-14 (medium): a task given back, then edited and left, is never written
    /// over by a late refusal of another of its agents; that one is saved beside it.
    @Test func aLateRefusalNeverWritesOverAnEditedDraft() {
        let (_, creator, _) = make()
        let origin = Self.chat(TaskDraft(prompt: "Original", picks: [TaskAgentPick(harness: "codex")]))
        // Given back once (another agent), then edited and saved under the same id.
        var edited = origin
        edited.prompt = "Edited"
        creator.taskDrafts.save(edited)
        creator.taskDraft.prompt = "Writing the next task"
        // A late refusal of the task's other agent.
        creator.taskOrigins["late"] = origin
        creator.restoreTaskDraft(after: "late", reason: "No")
        #expect(creator.taskDrafts.entry(origin.id)?.prompt == "Edited")
        #expect(Set(creator.taskDrafts.drafts.map(\.prompt)) == ["Edited", "Original"])
        #expect(creator.refusedTaskPlace("late") == .drafts)
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
        let made = creator.startTask(Self.chat(TaskDraft(prompt: "Ship it", picks: [claude, router])))
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
        creator.startTask(Self.chat(TaskDraft(prompt: "Go", picks: [TaskAgentPick(harness: "claude")])))
        await creator.settle()
        #expect(creator.taskRefusal == "The Mac said: Authentication required")
    }

    /// A refusal over a new task being written leaves that task alone and saves the refused one
    /// in Drafts (the toast says so).
    @Test func aRefusalOverANewDraftGoesToDrafts() async throws {
        let (_, creator, backend) = make()
        backend.result = { _ in .failure(WorkspaceCreationError("No")) }
        // The Mac answers only at `settle`: the person starts writing the next task first.
        let made = creator.startTask(Self.chat(TaskDraft(prompt: "First")))
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
        let made = creator.startTask(Self.chat(TaskDraft(prompt: "Go", picks: [TaskAgentPick(harness: "claude", model: "opus")])))
        #expect(mock.sentTasks.isEmpty)
        await creator.settle()
        #expect(mock.sentTasks == [AgentTask(prompt: "Go", model: "opus")])
        #expect(reports.isEmpty)

        mock.taskFailure = .uncertain("The connection dropped")
        creator.startTask(Self.chat(TaskDraft(prompt: "Again")))
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
        creator.startTask(Self.chat(draft))
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

    /// Captures 2026-11-13: drafts saved with older times listed oldest first.
    @Test func theListIsNewestFirstWhateverOrderTheyWereSavedIn() {
        let drafts = TaskDraftStore(directory: nil)
        drafts.save(TaskDraft(prompt: "middle"), now: Date(timeIntervalSince1970: 200))
        drafts.save(TaskDraft(prompt: "oldest"), now: Date(timeIntervalSince1970: 100))
        drafts.save(TaskDraft(prompt: "newest"), now: Date(timeIntervalSince1970: 300))
        #expect(drafts.drafts.map(\.prompt) == ["newest", "middle", "oldest"])
    }

    @Test func aPhotoIDIsNeverAPath() {
        #expect(TaskDraftDisk.isSafeName(UUID().uuidString))
        #expect(!TaskDraftDisk.isSafeName("../index.json"))
        #expect(!TaskDraftDisk.isSafeName("a/b"))
        #expect(!TaskDraftDisk.isSafeName(""))
    }
}


/// A terminal launch (classic's tasks): the agent's CLI with its model and the task, typed into
/// the new workspace's shell. Nothing in the prompt can run.
@MainActor @Suite struct TerminalLaunchTests {
    @Test func claudeAndCodexGetTheirCommands() {
        #expect(AgentTask(prompt: "Fix it", model: "sonnet", launch: .terminal, family: "claude").terminalLine()
            == "claude --model=$'sonnet' -- $'Fix it'\n")
        #expect(AgentTask(prompt: "Fix it", launch: .terminal, family: "codex").terminalLine() == "codex -- $'Fix it'\n")
        #expect(AgentTask(prompt: "Fix it", model: "default", launch: .terminal, family: "claude").terminalLine() == "claude -- $'Fix it'\n")
        #expect(AgentTask(prompt: "Fix it", launch: .terminal, family: "opencode").terminalLine() == nil)
    }

    @Test func thePromptIsOneQuotedWordWhateverItHolds() {
        let line = AgentTask(prompt: "it's `rm -rf ~` $(whoami)\\\nnext\u{1B}[2J\u{7F}line", launch: .terminal, family: "claude").terminalLine()
        #expect(line == "claude -- $'it\\'s `rm -rf ~` $(whoami)\\\\\\nnext[2Jline'\n")
        // One line: the only Return is the one that runs it.
        #expect(line?.filter { $0 == "\n" }.count == 1)
    }

    @Test func attachedFilesAreNamedAfterThePrompt() {
        let line = AgentTask(prompt: "Match this", launch: .terminal, family: "claude").terminalLine(attachmentPaths: ["/p/a.png"])
        #expect(line == "claude -- $'Match this\\n\\nAttached files (read them):\\n/p/a.png'\n")
    }

    /// Review 2026-11-14: a prompt or model starting with `-` is never an option; a model with a
    /// quote stays one word; the joiners Persian and emoji need are kept, the bidi overrides go.
    @Test func optionsAndScriptsAreSafe() {
        #expect(AgentTask(prompt: "--help me", model: "-x'y", launch: .terminal, family: "claude").terminalLine()
            == "claude --model=$'-x\\'y' -- $'--help me'\n")
        let persian = "می\u{200C}خواهم 👩\u{200D}💻 \u{202E}evil"
        #expect(AgentTask(prompt: persian, launch: .terminal, family: "codex").terminalLine()
            == "codex -- $'می\u{200C}خواهم 👩\u{200D}💻 evil'\n")
    }

    /// Review 2026-11-14: the agent runs only once `cd` to the task's folder worked.
    @Test func theAgentRunsInTheFolderOrNotAtAll() {
        let task = AgentTask(prompt: "Go", launch: .terminal, family: "claude")
        #expect(task.terminalLine(folder: "/Users/me/my repo") == "cd -- $'/Users/me/my repo' && claude -- $'Go'\n")
        #expect(task.terminalLine(folder: "~/code/a\\b") == "cd -- ~/$'code/a\\\\b' && claude -- $'Go'\n")
    }

    @Test func aTerminalTaskOpensATerminalWorkspaceAndTypesItsCommand() async throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let mock = MockWorkspaceCreationBackend(latency: .zero)
        let creator = WorkspaceCreator(store: store, backend: mock,
                                       defaults: try #require(UserDefaults(suiteName: "tl.\(UUID().uuidString)")))
        let made = creator.startTask(TaskDraft(prompt: "Fix it", picks: [TaskAgentPick(harness: "claude", model: "opus", name: "Claude Code",
                                                                                       family: "claude")], launch: .terminal))
        #expect(made.first?.tabs.first?.kind == .terminal)
        // As the Mac will list it (live run 16: a tab named for the agent flipped to the folder).
        #expect(made.first?.tabs.first?.title == "zsh")
        await creator.settle()
        #expect(mock.typedLines == ["claude --model=$'opus' -- $'Fix it'\n"])
        #expect(mock.sentTasks.isEmpty)
    }

    @Test func aChatTaskStillSendsItsFirstMessage() async throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let mock = MockWorkspaceCreationBackend(latency: .zero)
        let creator = WorkspaceCreator(store: store, backend: mock,
                                       defaults: try #require(UserDefaults(suiteName: "tl.\(UUID().uuidString)")))
        let file = TaskFile(name: "notes.md", data: Data("hi".utf8))
        creator.startTask(TaskDraft(prompt: "Go", files: [file], picks: [TaskAgentPick(harness: "claude")], launch: .chat))
        await creator.settle()
        #expect(mock.sentTasks.first?.files == [file])
        #expect(mock.typedLines.isEmpty)
    }
}

/// Drafts keep files and where the task runs; a draft saved before those were kept still reads.
@MainActor @Suite struct TaskDraftFilesTests {
    @Test func aDraftWithFilesAndATerminalLaunchResumesWithThem() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = TaskDraftStore(directory: folder)
        await store.load()
        let file = TaskFile(name: "spec.pdf", data: Data(repeating: 7, count: 2048))
        let draft = TaskDraft(prompt: "Read the spec", files: [file], launch: .terminal)
        store.save(draft)
        await store.flush()
        let again = TaskDraftStore(directory: folder)
        await again.load()
        let read = try #require(await again.draft(draft.id))
        #expect(read.files == [file] && read.launch == .terminal)
    }

    @Test func aDraftSavedBeforeFilesWereKeptReadsWithNoneAsAChat() throws {
        let json = #"[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","updatedAt":0,"prompt":"Old","imageIDs":[],"picks":[],"name":""}]"#
        let drafts = try JSONDecoder().decode([SavedTaskDraft].self, from: Data(json.utf8))
        #expect(drafts.first?.files.isEmpty == true && drafts.first?.launch == .chat)
    }

    /// Review 2026-11-14: an index that can't be read is never written over (its drafts would
    /// be lost); one bad entry costs only itself.
    @Test func anUnreadableIndexIsKeptAndABadEntryCostsOnlyItself() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let index = folder.appendingPathComponent("index.json")
        try Data("not json".utf8).write(to: index)
        let broken = TaskDraftStore(directory: folder)
        await broken.load()
        #expect(broken.isReadOnly)
        broken.save(TaskDraft(prompt: "New"))
        await broken.flush()
        #expect(try String(contentsOf: index, encoding: .utf8) == "not json")

        let good = #"{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","updatedAt":0,"prompt":"Kept","name":""}"#
        try Data("[\(good),{\"id\":42}]".utf8).write(to: index)
        let partial = TaskDraftStore(directory: folder)
        await partial.load()
        #expect(!partial.isReadOnly && partial.drafts.map(\.prompt) == ["Kept"])
    }

    /// Review 2026-11-14: a save made before the first read merges with the drafts on disk.
    @Test func aSaveBeforeTheFirstReadKeepsTheDraftsOnDisk() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = TaskDraftStore(directory: folder)
        await first.load()
        first.save(TaskDraft(prompt: "On disk"))
        await first.flush()
        let next = TaskDraftStore(directory: folder)
        next.save(TaskDraft(prompt: "Before the read"))
        await next.flush()
        let check = TaskDraftStore(directory: folder)
        await check.load()
        #expect(Set(check.drafts.map(\.prompt)) == ["On disk", "Before the read"])
    }

    @Test func filesCountAsSomethingToSave() {
        #expect(!TaskDraft(files: [TaskFile(name: "a", data: Data([1]))]).isEmpty)
    }
}
