import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
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

    @Test func theRecordCarriesIdlePauseDiagnosticsForMachineStatus() throws {
        let data = Data(#"{"id":"vm-diag","status":"running","idlePause":{"minutes":30,"lastCheckedAt":1700000000000,"idleSince":1699998000000,"lastApiActivityAt":1699999000000,"privateAddressKnown":true,"lastDecision":{"at":1700000000000,"outcome":"idle","reason":"idle","run":{"checked":8,"elapsedMs":120}}}}"#.utf8)
        let machine = try JSONDecoder().decode(CloudMachine.self, from: data)
        let idle = try #require(machine.idlePause)
        #expect(idle.minutes == 30)
        #expect(idle.lastCheckedAt == 1_700_000_000_000)
        #expect(idle.idleSince == 1_699_998_000_000)
        #expect(idle.lastApiActivityAt == 1_699_999_000_000)
        #expect(idle.privateAddressKnown)
        #expect(idle.lastDecision?.at == 1_700_000_000_000)
        #expect(idle.lastDecision?.outcome == "idle")
        #expect(idle.lastDecision?.reason == "idle")
        #expect(idle.lastDecision?.run.checked == 8)
        #expect(idle.lastDecision?.run.elapsedMs == 120)

        let fields = CloudHandlers.idlePauseFields(idle)
        #expect(fields["minutes"] == .int(30))
        #expect(fields["private_address_known"] == .bool(true))
        #expect(fields["last_checked_at"] == .int(1_700_000_000_000))
        #expect(fields["last_decision"] != .null)

        let services = MachineIconTests.services()
        let session = MachineIconTests.cloudMachine(services, id: "vm-diag")
        session.machine = machine
        let stats = try JSONDecoder().decode(CloudMachineStats.self, from: Data(#"{"state":"running"}"#.utf8))
        let text = CloudHandlers.describe(session, stats, now: Date(timeIntervalSince1970: 0))
        #expect(text.contains("idle pause: 30 minutes"))
        #expect(text.contains("idle pause decision: idle (idle)"))

        let appServer = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":"vm-next","status":"running","idlePauseMinutes":30,"idlePause":{"minutes":30,"lastCheckedAt":1700000000000,"idleSince":1699998000000,"lastApiActivityAt":1699999000000,"privateAddressKnown":true,"lastDecision":{"at":1700000000000,"outcome":"idle","reason":"idle","run":{"checked":8,"elapsedMs":120}}}}"#.utf8))
        let next = try #require(CloudMachine(next: appServer))
        #expect(next.idlePause?.lastDecision?.run.elapsedMs == 120)
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
        let header = CloudCreationRows.machine(f.session, compatibility: nil, updates: DaemonUpdateBoard())
        #expect(header.status == .pausedIdle)
        #expect(header.status != .failed)
        #expect(!header.status.needsAttention)
        #expect(SectionHeaderRowView.statusText(header.status, hostGroup: false) == "Paused (idle)")
        #expect(Strings.attentionStatus(.pausedIdle) == "Paused (idle)")

        f.session.machine.pauseReason = .user
        #expect(CloudCreationRows.machine(f.session, compatibility: nil, updates: DaemonUpdateBoard()).status == .paused)
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

    // MARK: One record (Machine Status)

    /// Machine Status reads the machine's record by itself. A record that went from live to not
    /// live suspends the session like a list refresh does: before, it only replaced the record, so
    /// the next refresh found "was not live", nothing suspended, and the header never read
    /// "Paused (idle)" while the link kept trying.
    @Test(.timeLimit(.minutes(1)))
    func oneRecordThatTurnedPausedSuspendsTheSession() async throws {
        let f = Self.pausedMachine(reason: nil)
        f.session.machine.status = .running
        f.session.connect()
        let session = f.session
        try await Self.waitUntil { session.linkPhase != .idle }
        #expect(session.stage != .paused(idle: true), "a live link is not a pause")

        var record = session.machine
        record.status = .paused
        record.pauseReason = .idle
        f.services.cloud.apply(record, to: session, read: f.services.cloud.beginRecordRead())

        #expect(session.machine.status == .paused)
        #expect(session.linkPhase == .idle, "suspended: the link stopped")
        #expect(!session.daemon.isStarting, "suspended: the daemon connection is down")
        #expect(session.stage == .paused(idle: true))
        session.disconnect()
    }

    /// The other direction: a record that turned live (the machine was resumed elsewhere)
    /// connects the session. Before, Machine Status left it disconnected.
    @Test(.timeLimit(.minutes(1)))
    func oneRecordThatTurnedLiveConnectsTheSession() async throws {
        let f = Self.pausedMachine(reason: .idle)
        let session = f.session
        #expect(!session.daemon.isStarting)

        var record = session.machine
        record.status = .running
        record.pauseReason = nil
        f.services.cloud.apply(record, to: session, read: f.services.cloud.beginRecordRead())

        #expect(session.machine.status == .running)
        try await Self.waitUntil { session.daemon.isStarting }
        session.disconnect()
    }

    /// Reads land out of order: a newer read found the machine paused and suspended it; an older
    /// read (a second Machine Status, or a list asked before it) that still says running lands
    /// after. It changes nothing: no record overwrite and no connect.
    @Test(.timeLimit(.minutes(1)))
    func anOlderRecordLandingAfterANewerOneChangesNothing() async throws {
        let f = Self.pausedMachine(reason: nil)
        f.session.machine.status = .running
        f.session.connect()
        let session = f.session, cloud = f.services.cloud
        try await Self.waitUntil { session.linkPhase != .idle }

        let olderStatus = cloud.beginRecordRead(), olderList = cloud.beginRecordRead(), newer = cloud.beginRecordRead()
        var paused = session.machine
        paused.status = .paused
        paused.pauseReason = .idle
        cloud.apply(paused, to: session, read: newer)
        #expect(session.stage == .paused(idle: true))

        var running = session.machine
        running.status = .running
        running.pauseReason = nil
        cloud.apply(running, to: session, read: olderStatus)
        cloud.reconcile([running], read: olderList)

        #expect(session.machine.status == .paused, "the newest read's record stays")
        #expect(session.linkPhase == .idle, "no connect from an older read")
        #expect(!session.daemon.isStarting)
        #expect(session.stage == .paused(idle: true))

        // A read asked after the newest one applies as before.
        cloud.apply(running, to: session, read: cloud.beginRecordRead())
        #expect(session.machine.status == .running)
        session.disconnect()
    }

    /// A list asked before a Machine Status read that found the machine lands after it without
    /// that machine (the list was read before the machine showed in it). It does not remove or
    /// disconnect the machine: the newer read saw it. A list asked later still removes it.
    @Test(.timeLimit(.minutes(1)))
    func anOlderListWithoutTheMachineDoesNotRemoveANewerRecord() throws {
        let f = Self.pausedMachine(reason: nil)
        let session = f.session, cloud = f.services.cloud
        let olderList = cloud.beginRecordRead(), status = cloud.beginRecordRead(machineID: f.session.machineID)
        var running = session.machine
        running.status = .running
        cloud.apply(running, to: session, read: status)

        cloud.reconcile([], read: olderList)
        #expect(f.services.machines.session(session.machineID) === session, "the newer read's machine stays")

        cloud.reconcile([], read: cloud.beginRecordRead())
        #expect(f.services.machines.session(session.machineID) == nil, "a newer list removes it")
    }

    /// A list must not remove a session while a newer Machine Status read is still outstanding:
    /// that response can be the only answer that reintroduces the machine after the list snapshot.
    @Test(.timeLimit(.minutes(1)))
    func anOlderListDefersRemovalUntilANewerRecordReadLands() throws {
        let f = Self.pausedMachine(reason: nil)
        let session = f.session, cloud = f.services.cloud
        let olderList = cloud.beginRecordRead()
        let newerStatus = cloud.beginRecordRead(machineID: session.machineID)
        var running = session.machine
        running.status = .running

        cloud.reconcile([], read: olderList)
        #expect(f.services.machines.session(session.machineID) === session,
                "the list cannot remove a machine while a newer record read is outstanding")

        cloud.apply(running, to: session, read: newerStatus)
        #expect(f.services.machines.session(session.machineID) === session)
        #expect(session.machine.status == .running)
        session.disconnect()
    }

    @Test func aDestroyedDetailCompletesADeferredListRemoval() {
        let f = Self.pausedMachine(reason: nil)
        let cloud = f.services.cloud, session = f.session
        let list = cloud.beginRecordRead()
        let status = cloud.beginRecordRead(machineID: session.machineID)
        cloud.reconcile([], read: list)
        #expect(f.services.machines.session(session.machineID) === session)
        var destroyed = session.machine
        destroyed.status = .destroyed
        cloud.apply(destroyed, to: session, read: status)
        #expect(f.services.machines.session(session.machineID) == nil)
        #expect(cloud.recordReadsOutstanding.isEmpty)
        #expect(!session.daemon.isStarting)
        // The older list cannot bring back a machine the newer detail declared destroyed.
        var stale = destroyed
        stale.status = .paused
        cloud.reconcile([stale], read: list)
        #expect(f.services.machines.session(session.machineID) == nil)
    }

    @Test func aDestroyedDetailRemovesWithoutWaitingForAList() {
        let f = Self.pausedMachine(reason: nil)
        let cloud = f.services.cloud, session = f.session
        let older = cloud.beginRecordRead(machineID: session.machineID)
        let detail = cloud.beginRecordRead(machineID: session.machineID)
        var destroyed = session.machine
        destroyed.status = .destroyed
        cloud.apply(destroyed, to: session, read: detail)
        #expect(f.services.machines.session(session.machineID) == nil)
        var stale = destroyed
        stale.status = .running
        cloud.apply(stale, to: session, read: older)
        #expect(session.machine.status == .destroyed)
        #expect(cloud.recordReadsOutstanding.isEmpty)
        #expect(!session.daemon.isStarting)
    }

    @Test func anOlderDestroyedDetailDoesNotRemoveANewerLiveRecord() {
        let f = Self.pausedMachine(reason: nil)
        let cloud = f.services.cloud, session = f.session
        let detail = cloud.beginRecordRead(machineID: session.machineID)
        cloud.reconcile([session.machine], read: cloud.beginRecordRead())
        var destroyed = session.machine
        destroyed.status = .destroyed
        cloud.apply(destroyed, to: session, read: detail)
        #expect(f.services.machines.session(session.machineID) === session)
        #expect(session.machine.status == .paused)
        session.disconnect()
    }

    /// A failed or cancelled Machine Status read has no future record to preserve.
    @Test(.timeLimit(.minutes(1)))
    func aFailedRecordReadDoesNotKeepAnOmittedMachine() throws {
        let f = Self.pausedMachine(reason: nil)
        let cloud = f.services.cloud
        let list = cloud.beginRecordRead()
        let status = cloud.beginRecordRead(machineID: f.session.machineID)
        cloud.finishRecordRead(status)
        cloud.reconcile([], read: list)
        #expect(f.services.machines.session(f.session.machineID) == nil)
    }

    /// A failed read must release a removal already deferred by an earlier list.
    @Test(.timeLimit(.minutes(1)))
    func aFailedRecordReadFinishesAnAlreadyDeferredRemoval() throws {
        let f = Self.pausedMachine(reason: nil)
        let cloud = f.services.cloud
        let list = cloud.beginRecordRead()
        let status = cloud.beginRecordRead(machineID: f.session.machineID)
        cloud.reconcile([], read: list)
        #expect(f.services.machines.session(f.session.machineID) === f.session)
        cloud.finishRecordRead(status)
        #expect(f.services.machines.session(f.session.machineID) == nil,
                "failure retries the removal without waiting for another refresh")
        #expect(f.session.linkPhase == .idle)
    }

    @Test(.timeLimit(.minutes(1)))
    func aStatusReadForAnotherMachineDoesNotDelayRemoval() throws {
        let f = Self.pausedMachine(reason: nil)
        let cloud = f.services.cloud
        let other = MachineIconTests.cloudMachine(f.services, id: "vm-other")
        other.machine.status = .paused
        defer { other.disconnect() }
        let list = cloud.beginRecordRead()
        let status = cloud.beginRecordRead(machineID: other.machineID)

        cloud.reconcile([other.machine], read: list)
        #expect(f.services.machines.session(f.session.machineID) == nil,
                "B's pending status must not keep omitted A registered")
        #expect(f.services.machines.session(other.machineID) === other)
        cloud.finishRecordRead(status)
    }

    @Test(.timeLimit(.minutes(1)))
    func removalWaitsUntilEveryNewerReadForThatMachineFinishes() throws {
        let f = Self.pausedMachine(reason: nil)
        let cloud = f.services.cloud
        let list = cloud.beginRecordRead()
        let first = cloud.beginRecordRead(machineID: f.session.machineID)
        let second = cloud.beginRecordRead(machineID: f.session.machineID)
        cloud.reconcile([], read: list)
        cloud.finishRecordRead(first)
        #expect(f.services.machines.session(f.session.machineID) === f.session)
        cloud.finishRecordRead(second)
        #expect(f.services.machines.session(f.session.machineID) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aNewerListSupersedesADeferredRemoval() throws {
        let f = Self.pausedMachine(reason: nil)
        let cloud = f.services.cloud
        let list = cloud.beginRecordRead()
        let status = cloud.beginRecordRead(machineID: f.session.machineID)
        cloud.reconcile([], read: list)
        cloud.reconcile([f.session.machine], read: cloud.beginRecordRead())
        cloud.finishRecordRead(status)
        #expect(f.services.machines.session(f.session.machineID) === f.session)
        f.session.disconnect()
    }

    @Test func listTicketsNeverAccumulateOrRetireAnotherMachinesStatusRead() {
        let cases: [(list: [CloudMachine], disabled: Bool)] = [
            ([], false),
            ([CloudMachine(id: "new-machine", status: .paused)], false),
            ([CloudMachine(id: "destroyed-machine", status: .destroyed)], false),
            ([], true),
        ]
        for item in cases {
            let services = MachineIconTests.services()
            let cloud = services.cloud
            cloud.applyPolicy(disabled: item.disabled)
            let status = cloud.beginRecordRead(machineID: "status-machine")
            for _ in 0..<10 {
                let list = cloud.beginRecordRead()
                #expect(cloud.recordReadsOutstanding == [status: "status-machine"], "lists only need an ordering ticket")
                cloud.reconcile(item.list, read: list)
                cloud.finishRecordRead(list)
                #expect(cloud.recordReadsOutstanding == [status: "status-machine"], "every list path preserves only the pending status read")
            }
            cloud.finishRecordRead(status)
            #expect(cloud.recordReadsOutstanding.isEmpty)
            for session in services.machines.cloud { session.disconnect() }
        }
    }

    /// A newer list that first shows a machine (and creates its session) holds that machine's
    /// ticket: an older list landing after it without the machine does not remove it, and an
    /// older Machine Status record does not overwrite it.
    @Test(.timeLimit(.minutes(1)))
    func aMachineANewerListAddedKeepsThatListsTicket() throws {
        let services = MachineIconTests.services()
        let cloud = services.cloud, id = "vm-listed-\(UUID().uuidString.prefix(8))"
        let olderStatus = cloud.beginRecordRead(), olderList = cloud.beginRecordRead(), newerList = cloud.beginRecordRead()
        let listed = CloudMachine(id: id, status: .paused, displayName: "Listed VM")
        cloud.reconcile([listed], read: newerList)
        // A test process has no cmux-tui for a legacy link, so the list's create may make no
        // session: stand one in, as that create would have.
        let session = services.machines.session(id) ?? MachineIconTests.cloudMachine(services, id: id)
        session.machine = listed

        var running = listed
        running.status = .running
        cloud.apply(running, to: session, read: olderStatus)
        #expect(session.machine.status == .paused, "an older record does not overwrite the newer list's")
        cloud.reconcile([], read: olderList)
        #expect(services.machines.session(id) === session, "an older list does not remove it")
        session.disconnect()
    }

    /// Waits up to 20 seconds for `condition`, which the session's connect makes true.
    static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(condition())
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
