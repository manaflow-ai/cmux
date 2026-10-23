import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// cmux Cloud pauses an idle machine (web/services/vms/idlePause.ts, 30 minutes by default). The
/// app shows such a machine as "Paused (idle)", never "Failed"; one click on Resume, or any
/// attach (open a workspace or terminal, ssh, a terminal's Connect), resumes it through Resume
/// Machine's own path; and `cloud set-idle-pause` sets a machine's timeout to Off, 15, 30, 60
/// or 120 minutes, answering a CLI or agent with the stored value.
@MainActor @Suite(.serialized)
struct CloudIdlePauseTests {
    static func pausedMachine(reason: CloudMachine.PauseReason?) -> (services: AppServices, context: AppActionContext, session: CloudMachineSession) {
        let services = MachineIconTests.services()
        let session = MachineIconTests.cloudMachine(services, id: "vm-idle-\(UUID().uuidString.prefix(8))")
        session.machine.status = .paused
        session.machine.pauseReason = reason
        return (services, AppActionContext(services: services), session)
    }

    // MARK: The record

    @Test func theRecordCarriesWhyItIsPausedAndItsIdleTimeout() throws {
        let data = Data(#"{"id":"vm-1","status":"paused","pauseReason":"idle","idlePauseMinutes":30}"#.utf8)
        let machine = try JSONDecoder().decode(CloudMachine.self, from: data)
        #expect(machine.pauseReason == .idle)
        #expect(machine.idlePauseMinutes == 30)
        let user = try JSONDecoder().decode(CloudMachine.self, from: Data(#"{"id":"vm-2","status":"paused","pauseReason":"user","idlePauseMinutes":0}"#.utf8))
        #expect(user.pauseReason == .user)
        #expect(user.idlePauseMinutes == 0)
    }

    @Test func anOlderServerOrAnUnknownReasonDecodesAsNone() throws {
        let old = try JSONDecoder().decode(CloudMachine.self, from: Data(#"{"id":"vm-old","status":"paused"}"#.utf8))
        #expect(old.pauseReason == nil)
        #expect(old.idlePauseMinutes == nil)
        let odd = try JSONDecoder().decode(CloudMachine.self, from: Data(#"{"id":"vm-odd","status":"paused","pauseReason":"billing","idlePauseMinutes":"x"}"#.utf8))
        #expect(odd.pauseReason == nil)
        #expect(odd.idlePauseMinutes == nil)
    }

    @Test func theChoicesAreOffFifteenThirtySixtyAndOneTwenty() {
        #expect(CloudMachine.idlePauseChoices == [0, 15, 30, 60, 120])
    }

    // MARK: Paused is not failed

    @Test func anIdlePausedMachineReadsPausedIdleNotFailed() {
        let stage = CloudMachineStageInput(machineStatus: .paused, pauseReason: .idle).stage
        #expect(stage == .paused(idle: true))
        #expect(stage.failure == nil, "a paused machine is not a failure")
        #expect(stage.isFinished)
        #expect(stage.name == "paused")
        #expect(CloudStrings.stage(stage) == "Paused (idle)")
        #expect(CloudStrings.stage(stage) != CloudStrings.stage(.failed("x")))
    }

    @Test func aMachineAPersonPausedReadsPaused() {
        for reason in [CloudMachine.PauseReason.user, nil] {
            let stage = CloudMachineStageInput(machineStatus: .paused, pauseReason: reason).stage
            #expect(stage == .paused(idle: false), "\(String(describing: reason))")
            #expect(CloudStrings.stage(stage) == "Paused")
        }
    }

    @Test func aResumingMachineIsStartingAndAFailedResumeSaysWhy() {
        #expect(CloudMachineStageInput(machineStatus: .paused, pauseReason: .idle, resuming: true).stage == .booting)
        #expect(CloudMachineStageInput(machineStatus: .paused, pauseReason: .idle, resumeFailure: "quota").stage == .failed("quota"))
    }

    /// An app link ends when its machine pauses ("disconnected, click to connect"): on a paused
    /// machine that is the pause, not a failure. A live machine's ended link still fails.
    @Test func anEndedAppLinkOnAPausedMachineReadsPausedNotFailed() {
        let ended = CloudMachineStageInput(machineStatus: .paused, link: .failed("link down"), linkEnded: "link down", pauseReason: .idle)
        #expect(ended.stage == .paused(idle: true))
        #expect(ended.stage.failure == nil)
        let live = CloudMachineStageInput(machineStatus: .running, link: .failed("link down"), linkEnded: "link down")
        #expect(live.stage == .failed("link down"))
        // A click's connect that was to start the paused machine and failed says why.
        let refused = CloudMachineStageInput(machineStatus: .paused, link: .failed("no capacity"), linkEnded: "no capacity",
                                             pauseReason: .idle, resumeFailure: "no capacity")
        #expect(refused.stage == .failed("no capacity"))
    }

    @Test func theSidebarHeaderSaysPausedIdleAndNeedsNoAttention() {
        let f = Self.pausedMachine(reason: .idle)
        let header = CloudCreationRows.machine(f.session, compatibility: nil)
        #expect(header.status == .pausedIdle)
        #expect(header.status != .failed)
        #expect(!header.status.needsAttention)
        #expect(SectionHeaderRowView.statusText(header.status, hostGroup: false) == "Paused (idle)")
        #expect(Strings.attentionStatus(.pausedIdle) == "Paused (idle)")

        f.session.machine.pauseReason = .user
        #expect(CloudCreationRows.machine(f.session, compatibility: nil).status == .paused)
        #expect(SectionHeaderRowView.statusWords(.paused) == "Paused")
    }

    @Test func aPausedMachinesCreationRowHasNoSpinner() throws {
        let f = Self.pausedMachine(reason: .idle)
        let creation = CloudMachineCreation(windowID: nil, session: f.session)
        let row = try #require(CloudCreationRows.adding([creation], to: []).flatMap(\.workspaces).first)
        #expect(row.progress == nil)
        #expect(row.status == "Paused (idle)")
    }

    @Test func aPausedMachinesHoverCardIsQuietNotDanger() {
        #expect(WorkspaceHoverCardContent.connectionTone(.pausedIdle) == .secondary)
        #expect(WorkspaceHoverCardContent.connectionTone(.paused) == .secondary)
    }

    @Test func theProgressViewOffersOneClickResume() {
        let f = Self.pausedMachine(reason: .idle)
        let creation = CloudMachineCreation(windowID: nil, session: f.session)
        let view = CloudMachineProgressView(creation: creation, actions: .init(retry: { _ in }, dismiss: { _ in }))
        #expect(view.showsButtons)
        #expect(view.primaryButtonTitle == CloudStrings.resume)
        #expect(!view.detailText.contains(CloudStrings.progressFailed("")), "paused must not read as a failed start")
    }

    // MARK: Attach resumes

    @Test(.timeLimit(.minutes(1)))
    func attachingToAPausedMachineResumesItThroughResumeMachine() async {
        let f = Self.pausedMachine(reason: .idle)
        var resumed: [String] = []
        f.session.resumer = { [session = f.session] id in
            resumed.append(id)
            session.machine.status = .running
        }
        f.session.attach(origin: .user)
        #expect(f.session.resuming)
        #expect(f.session.stage == .booting)
        f.session.attach(origin: .user) // a second attach while it resumes starts no second resume
        let session = f.session
        for await busy in ObservationStream({ session.resuming }) where !busy { break }
        #expect(resumed == [f.session.machineID])
        #expect(f.session.machine.status == .running)
        f.session.disconnect()
    }

    @Test func attachingToALiveMachineResumesNothing() {
        let f = Self.pausedMachine(reason: nil)
        f.session.machine.status = .running
        var resumed = 0
        f.session.resumer = { _ in resumed += 1 }
        f.session.attach(origin: .user)
        #expect(!f.session.resuming)
        #expect(resumed == 0)
        f.session.disconnect()
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedResumeShowsItsReason() async {
        let f = Self.pausedMachine(reason: .idle)
        f.session.resumer = { _ in throw ActionFailure(message: "no capacity") }
        f.session.attach(origin: .user)
        let session = f.session
        for await busy in ObservationStream({ session.resuming }) where !busy { break }
        #expect(f.session.stage.failure?.contains("no capacity") == true)
        f.session.disconnect()
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedResumeDoesNotOutliveTheNextPause() async {
        let f = Self.pausedMachine(reason: .idle)
        f.session.resumer = { _ in throw ActionFailure(message: "no capacity") }
        f.session.attach(origin: .user)
        let session = f.session
        for await busy in ObservationStream({ session.resuming }) where !busy { break }
        #expect(f.session.resumeFailure != nil)
        // The machine is paused again (another pause, a reconcile): the old failure no longer applies.
        f.session.suspend()
        #expect(f.session.resumeFailure == nil)
        #expect(f.session.stage == .paused(idle: true))
        f.session.disconnect()
    }

    /// The app reads the machine list on launch and activation only, so a machine the idle
    /// auto-pause parked while cmux stayed in front still reads running here. An attach reads the
    /// record again first, finds it paused and resumes it.
    @Test(.timeLimit(.minutes(1)))
    func anAttachToAStaleRunningRecordReadsItAgainAndResumes() async {
        let f = Self.pausedMachine(reason: nil)
        f.session.machine.status = .running
        var reads: [Bool] = []
        var resumed = 0
        f.session.refresher = { [session = f.session] force in
            reads.append(force)
            session.machine.status = .paused
            session.machine.pauseReason = .idle
        }
        f.session.resumer = { _ in
            resumed += 1
            throw ActionFailure(message: "no capacity")
        }
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: f.session.machineID), arguments: [:], origin: .cli)
        #expect(CloudHandlers.attachable(f.session))
        await #expect(throws: ActionFailure.self) { try await CloudHandlers.attached(f.session, invocation, within: .seconds(20)) }
        #expect(reads == [true])
        #expect(resumed == 1)
        #expect(f.session.stage.failure?.contains("no capacity") == true)
        f.session.disconnect()
    }

    @Test(.timeLimit(.minutes(1)))
    func anAttachToAPausedMachineWaitsForItsResume() async {
        let f = Self.pausedMachine(reason: .idle)
        var reads = 0
        f.session.refresher = { _ in reads += 1 }
        f.session.resumer = { _ in throw ActionFailure(message: "quota reached") }
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: f.session.machineID), arguments: [:], origin: .cli)
        do {
            try await CloudHandlers.attached(f.session, invocation, within: .seconds(20))
            Issue.record("a failed resume must fail the attach")
        } catch let failure as ActionFailure {
            #expect(failure.message.contains("quota reached"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(reads == 0, "a record that already reads paused is not read again")
        f.session.disconnect()
    }

    // MARK: The setting

    @Test func theSettingIsACLIActionWithExactlyTheFiveChoices() throws {
        let services = MachineIconTests.services()
        let descriptor = try #require(services.registry.descriptor(for: "cloudSetIdlePause"))
        #expect(descriptor.cliName == "cloud set-idle-pause")
        #expect(descriptor.targets == [.machine])
        #expect(descriptor.surfaces.contains(.contextMenu))
        let argument = try #require(descriptor.arguments.first)
        #expect(argument.name == "minutes")
        guard case .enumeration(let cases) = argument.kind else {
            Issue.record("minutes is not a choice")
            return
        }
        #expect(cases.map(\.value) == ["off", "15", "30", "60", "120"])
    }

    @Test(arguments: [ActionOrigin.cli, .mcp, .script])
    func aCLIRunGetsTheStoredTimeoutBack(origin: ActionOrigin) async throws {
        let f = Self.pausedMachine(reason: nil)
        var stored: [(String, Int)] = []
        for (text, minutes) in [("off", 0), ("15", 15), ("60", 60)] {
            let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: f.session.machineID),
                                              arguments: ["minutes": .string(text)], origin: origin)
            let run = f.services.registry.capturingRun {
                do { try CloudHandlers.setIdlePause(invocation, f.context) { stored.append(($0, $1)) } } catch { Issue.record("refused: \(error)") }
            }
            let task = try #require(run.results.first)
            guard case .success(let fields) = await task.value else {
                Issue.record("set-idle-pause failed")
                return
            }
            #expect(fields["machine_id"] == .string(f.session.machineID))
            #expect(fields["idle_pause_minutes"] == .int(minutes))
        }
        #expect(stored.map(\.1) == [0, 15, 60])
        #expect(stored.allSatisfy { $0.0 == f.session.machineID })
    }

    @Test(arguments: ["45", "1", "never", "", "-15"])
    func aTimeoutThatIsNotAChoiceIsRefused(text: String) {
        let f = Self.pausedMachine(reason: nil)
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: f.session.machineID),
                                          arguments: ["minutes": .string(text)], origin: .cli)
        var stored = 0
        #expect(throws: ActionFailure.self) {
            try CloudHandlers.setIdlePause(invocation, f.context) { _, _ in stored += 1 }
        }
        #expect(stored == 0)
    }
}
