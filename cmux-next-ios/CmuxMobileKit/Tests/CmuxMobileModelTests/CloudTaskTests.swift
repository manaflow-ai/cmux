import Foundation
import Testing
@testable import CmuxMobileModel

/// New Task on a Cloud machine: the place picker offers the Cloud machines the Mac lists, and
/// Start hands the machine and the prompt to the shell (which opens its Claude chat).
@MainActor @Suite struct CloudTaskTests {
    let defaults: UserDefaults
    init() throws { defaults = try #require(UserDefaults(suiteName: "cmuxMobile.tests.cloudTask.\(UUID().uuidString)")) }

    static let box = CloudTaskTarget(teamID: "team-1", machineID: "vm-1", name: "Build box", macID: "mac-studio")

    func make(listed: [CloudTaskTarget]? = [box]) -> WorkspaceCreator {
        let backend = ScriptedBackend()
        backend.creatable = ["mac-studio"]
        backend.options = WorkspaceCreationOptions(directories: true, agents: [""], browser: true)
        let creator = WorkspaceCreator(store: AppStore.mock(tabMemory: .inMemory()), backend: backend, defaults: defaults,
                                       taskDrafts: TaskDraftStore(directory: nil))
        creator.loadCloudTaskTargets = { listed }
        return creator
    }

    @Test func theCloudMachinesTheMacListsAreOfferedAndAFailedReadKeepsThem() async {
        let creator = make()
        #expect(creator.cloudTaskTargets.isEmpty)
        await creator.refreshCloudTaskTargets()
        #expect(creator.cloudTaskTargets == [Self.box])
        creator.loadCloudTaskTargets = { nil }
        await creator.refreshCloudTaskTargets()
        #expect(creator.cloudTaskTargets == [Self.box])
    }

    @Test func aCloudTaskNeedsOnlyAPromptOnAListedMachineAndTakesNoAttachments() async {
        let creator = make()
        var draft = TaskDraft(prompt: "go")
        draft.chooseCloud(Self.box.id)
        // Not listed yet: unreachable.
        #expect(creator.taskBlocker(draft) == .noCloud)
        await creator.refreshCloudTaskTargets()
        #expect(creator.taskBlocker(draft) == nil)
        draft.prompt = " "
        #expect(creator.taskBlocker(draft) == .noPrompt)
        draft.prompt = "go"
        draft.images = [TaskImage(data: Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: 0, count: 12)))]
        #expect(creator.taskBlocker(draft) == .cloudTextOnly)
    }

    @Test func choosingAMacLeavesTheCloudMachineAndKeepsTheMacsPicks() {
        var draft = TaskDraft(picks: [TaskAgentPick(harness: "codex")], macID: "mac-studio")
        draft.chooseCloud(Self.box.id)
        #expect(draft.cloudID == Self.box.id && draft.picks.count == 1)
        draft.chooseMac("mac-studio")
        #expect(draft.cloudID == nil && draft.picks.count == 1)
    }

    @Test func startHandsTheMachineAndPromptToTheShellAndKeepsTheMachineChosen() async {
        let creator = make()
        await creator.refreshCloudTaskTargets()
        var opened: [(CloudTaskTarget, String)] = []
        creator.openCloudTask = { opened.append(($0, $1)) }
        creator.taskDraft.prompt = "  Fix the flaky upload test \n"
        creator.taskDraft.chooseCloud(Self.box.id)
        creator.saveTaskDraft()
        let sentID = creator.taskDraft.id
        #expect(creator.startCloudTask(creator.taskDraft))
        #expect(opened.count == 1 && opened.first?.0 == Self.box && opened.first?.1 == "Fix the flaky upload test")
        // Sent: out of the drafts; the next task starts empty on the same machine.
        #expect(!creator.taskDrafts.drafts.contains { $0.id == sentID })
        #expect(creator.taskDraft.prompt.isEmpty && creator.taskDraft.cloudID == Self.box.id)
        // A blocked one sends nothing.
        #expect(!creator.startCloudTask(creator.taskDraft))
        #expect(opened.count == 1)
    }

    @Test func aSavedDraftAndTheSetupRememberTheCloudMachine() async throws {
        let creator = make()
        creator.taskDraft.prompt = "Later"
        creator.taskDraft.chooseCloud(Self.box.id)
        let id = creator.taskDraft.id
        creator.leaveTaskComposer(keep: true)
        #expect(creator.taskDraft.cloudID == Self.box.id)
        #expect(await creator.resumeTaskDraft(id))
        #expect(creator.taskDraft.cloudID == Self.box.id)
        // An older saved draft (no cloudID) reads as a Mac's.
        let old = try JSONDecoder().decode(SavedTaskDraft.self, from: Data(
            #"{"id":"\#(UUID().uuidString)","updatedAt":0,"prompt":"x"}"#.utf8))
        #expect(old.cloudID == nil)
        // The setup comes back after a relaunch.
        let again = make()
        #expect(again.taskDraft.cloudID == Self.box.id)
    }
}
