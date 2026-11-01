import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// A cmux-next Cloud machine's in-between states (backend protocol `CloudMachineStatus`): the
/// server answers Pause, Resume and Kill at once and runs the provider call after, so the record
/// reads `pausing`, `starting` or `deleting` meanwhile. The app shows them as Pausing…, Resuming…
/// and Deleting… (never Paused while it still pauses, never gone while it is deleted), offers no
/// power action that would clash, reads `pause_reason` as the backend spells it, and shows the
/// record's `error` when a provider call failed after the server answered.
@MainActor @Suite(.serialized)
struct CloudMachineChangeStateTests {
    private static func record(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private static func next(_ json: String) throws -> CloudMachine {
        try #require(CloudMachine(next: try record(json)))
    }

    private static func session(status: CloudMachine.Status) -> CloudMachineSession {
        let services = MachineIconTests.services()
        let session = MachineIconTests.cloudMachine(services, id: "vm-change-\(UUID().uuidString.prefix(8))")
        session.machine.status = status
        return session
    }

    private actor StartingLinkResolver: CloudLinkResolver {
        private(set) var attempts = 0
        private var waiting: (Int, CheckedContinuation<Void, Never>)?
        func waitForAttempts(_ count: Int) async {
            if attempts >= count { return }
            await withCheckedContinuation { waiting = (count, $0) }
        }
        func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
            attempts += 1
            if let (count, continuation) = waiting, attempts >= count {
                waiting = nil
                continuation.resume()
            }
            throw CloudLinkError.disconnected(reason: "provider still starting")
        }
        func close(_ key: CloudLinkKey) async {}
    }

    private actor ResumeLinkResolver: CloudLinkResolver {
        private(set) var attempts = 0
        private var opened: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        private var released = false
        private var secondAttempt: CheckedContinuation<Void, Never>?

        func waitForOpen() async {
            if attempts > 0 { return }
            await withCheckedContinuation { opened = $0 }
        }

        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }

        func waitForAttempts(_ count: Int) async {
            if attempts >= count { return }
            await withCheckedContinuation { secondAttempt = $0 }
        }

        func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
            attempts += 1
            if attempts == 1 {
                opened?.resume()
                opened = nil
                if !released { await withCheckedContinuation { releaseWaiter = $0 } }
            } else if let continuation = secondAttempt {
                secondAttempt = nil
                continuation.resume()
            }
            return CloudLinkSocket(key: key, path: "/tmp/cloud-change-test.sock", generation: 1)
        }

        func close(_ key: CloudLinkKey) async {}
    }

    @Test(.timeLimit(.minutes(1)))
    func runningRetriesAnAppLinkThatFailedWhileStarting() async throws {
        let services = MachineIconTests.services()
        let resolver = StartingLinkResolver()
        let session = CloudMachineSession(machine: CloudMachine(id: "resume-retry", status: .running),
            appLink: CloudLinkSession(key: CloudLinkKey(machine: "resume-retry"), resolver: resolver),
            localIdentity: { nil }, mainWork: services.mainWork)
        defer { session.disconnect() }
        session.connect()
        for await ended in ObservationStream({ session.linkEnded != nil }) where ended { break }
        #expect(await resolver.attempts == 1)
        session.applyRecord(CloudMachine(id: session.machineID, status: .starting))
        session.applyRecord(CloudMachine(id: session.machineID, status: .running))
        await resolver.waitForAttempts(2)
        for await ended in ObservationStream({ session.linkEnded != nil }) where ended { break }
        #expect(await resolver.attempts == 2)
        session.applyRecord(CloudMachine(id: session.machineID, status: .running))
        await Task.yield()
        #expect(await resolver.attempts == 2, "repeated running lists do not retry a settled failure")
    }

    @Test(.timeLimit(.minutes(1)))
    func runningBeforeResumeAcknowledgementConnectsWhenPendingClears() async throws {
        let services = MachineIconTests.services()
        let cloud = services.cloud
        let resolver = StartingLinkResolver()
        let session = CloudMachineSession(machine: CloudMachine(id: "early-running", status: .paused),
            appLink: CloudLinkSession(key: CloudLinkKey(machine: "early-running"), resolver: resolver),
            localIdentity: { nil }, mainWork: services.mainWork)
        services.machines.add(session)
        defer { cloud.changes.stop(); session.disconnect() }
        let running = CloudMachine(id: session.machineID, status: .running,
            updatedAt: Date(timeIntervalSince1970: 2))
        try await cloud.changes.run(.starting, machineID: session.machineID, of: { session }) {
            cloud.apply(running, to: session, read: cloud.beginRecordRead(machineID: session.machineID))
            #expect(session.machine.status == .running)
            #expect(session.machine.pendingChange == .starting)
            #expect(await resolver.attempts == 0, "the request is still in flight")
        }
        cloud.apply(running, to: session, read: cloud.beginRecordRead(machineID: session.machineID))
        #expect(session.machine.pendingChange == nil)
        await resolver.waitForAttempts(1)
        for await ended in ObservationStream({ session.linkEnded != nil }) where ended { break }
        #expect(await resolver.attempts == 1, "settling resume connects even across running -> running")
        cloud.apply(running, to: session, read: cloud.beginRecordRead(machineID: session.machineID))
        await Task.yield()
        #expect(await resolver.attempts == 1, "later identical records do not restart the connection")
    }

    @Test func transitionsRejectUserConnectAttachAndActionCallers() async throws {
        let services = MachineIconTests.services()
        let resolver = StartingLinkResolver()
        let session = CloudMachineSession(machine: CloudMachine(id: "transition-gate", status: .running),
            appLink: CloudLinkSession(key: CloudLinkKey(machine: "transition-gate"), resolver: resolver),
            localIdentity: { nil }, mainWork: services.mainWork)
        defer { session.disconnect() }
        for status: CloudMachine.Status in [.pausing, .starting, .deleting] {
            session.machine.pendingChange = status
            session.connect(origin: .user)
            session.attach(origin: .user)
            #expect(session.linkPhase == .idle)
            #expect(!CloudHandlers.attachable(session))
            #expect(throws: ActionFailure.self) { try CloudHandlers.requireAttachableState(session) }
        }
        #expect(await resolver.attempts == 0)
    }

    @Test func killAcknowledgementReportsPendingDeletion() {
        let fields = CloudHandlers.deletionPending("vm-delete")
        #expect(fields["status"] == .string("deleting"))
        #expect(fields["pending"] == .bool(true))
        #expect(fields["machine_id"] == .string("vm-delete"))
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedPauseReconnectsAConnectionInterruptedByTheMutation() async {
        let services = MachineIconTests.services()
        let resolver = ResumeLinkResolver()
        let session = CloudMachineSession(machine: CloudMachine(id: "mutation-reconnect", status: .running),
            appLink: CloudLinkSession(key: CloudLinkKey(machine: "mutation-reconnect"), resolver: resolver),
            localIdentity: { nil }, mainWork: services.mainWork)
        defer { session.disconnect() }

        session.connect()
        await resolver.waitForOpen()
        for await phase in ObservationStream({ session.linkPhase }) where phase == .starting { break }
        let mutation = UUID()
        session.machine.pendingChange = .pausing
        session.machine.pendingMutationID = mutation
        await resolver.release()
        for await phase in ObservationStream({ session.linkPhase }) where phase == .idle { break }

        // CloudMachineChanges rolls back the failed pause and invokes this callback only while
        // it still owns the mutation; a newer mutation must not reconnect this session.
        session.machine.pendingChange = nil
        session.machine.pendingMutationID = nil
        session.mutationFailed(UUID())
        #expect(session.linkPhase == .idle, "an unrelated rollback cannot authorize reconnect")
        #expect(await resolver.attempts == 1)
        session.mutationFailed(mutation)
        await resolver.waitForAttempts(2)
        #expect(await resolver.attempts == 2)
    }

    @Test(arguments: [CloudMachine.Status.pausing, .starting])
    func aFailedKillPreservesTheOlderMutation(change: CloudMachine.Status) async throws {
        let session = Self.session(status: change == .starting ? .paused : .running)
        defer { session.disconnect() }
        let changes = CloudMachineChanges()
        defer { changes.stop() }
        try await changes.run(change, machineID: session.machineID, of: { session }) {
            await #expect(throws: ActionFailure.self) {
                try await changes.run(.deleting, machineID: session.machineID, of: { session }) {
                    throw ActionFailure(message: "delete refused")
                }
            }
            #expect(session.machine.pendingChange == change)
        }
        let stale = CloudMachine(id: session.machineID, status: session.machine.status)
        #expect(changes.pendingStatus(for: stale) == change)
        changes.listed([stale], refresh: {})
        #expect(changes.isSettling, "the older provider transition still needs polling")
        let terminal = CloudMachine(id: session.machineID, status: change == .starting ? .running : .paused)
        #expect(changes.pendingStatus(for: terminal) == nil)
        changes.listed([terminal], refresh: {})
        #expect(!changes.isSettling)
    }

    @Test func anOlderFailureCannotEraseANewerMutationOfTheSameKind() async throws {
        let session = Self.session(status: .running)
        defer { session.disconnect() }
        let changes = CloudMachineChanges()
        defer { changes.stop() }
        await #expect(throws: ActionFailure.self) {
            try await changes.run(.deleting, machineID: session.machineID, of: { session }) {
                try await changes.run(.deleting, machineID: session.machineID, of: { session }) {}
                throw ActionFailure(message: "older delete refused")
            }
        }
        #expect(session.machine.pendingChange == .deleting)
        #expect(changes.pendingStatus(for: CloudMachine(id: session.machineID, status: .running)) == .deleting)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedKillCannotRecoverThePausesInterruptedConnection() async throws {
        let services = MachineIconTests.services()
        let resolver = ResumeLinkResolver()
        let session = CloudMachineSession(machine: CloudMachine(id: "overlapping-power", status: .running),
            appLink: CloudLinkSession(key: CloudLinkKey(machine: "overlapping-power"), resolver: resolver),
            localIdentity: { nil }, mainWork: services.mainWork)
        let changes = CloudMachineChanges()
        defer { changes.stop(); session.disconnect() }
        session.connect()
        await resolver.waitForOpen()
        do {
            try await changes.run(.pausing, machineID: session.machineID, of: { session },
                                  onRollback: { session.mutationFailed($0) }) {
                let pauseID = session.machine.pendingMutationID
                await resolver.release()
                for await phase in ObservationStream({ session.linkPhase }) where phase == .idle { break }
                do {
                    try await changes.run(.deleting, machineID: session.machineID, of: { session },
                                          onRollback: { session.mutationFailed($0) }) {
                        #expect(session.machine.pendingMutationID != pauseID)
                        throw ActionFailure(message: "kill rejected")
                    }
                    Issue.record("Expected the kill request to fail")
                } catch is ActionFailure {
                    // The rejected kill must leave the older pause in charge.
                }
                #expect(session.machine.pendingMutationID == pauseID)
                #expect(session.machine.shownStatus == .pausing)
                #expect(await resolver.attempts == 1)
                throw ActionFailure(message: "pause rejected")
            }
            Issue.record("Expected the pause request to fail")
        } catch is ActionFailure {
            // Only this rollback may recover the interrupted connection.
        }
        await resolver.waitForAttempts(2)
        #expect(await resolver.attempts == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func providerFailureBeforeAcknowledgementRecoversWhenItSettles() async throws {
        let services = MachineIconTests.services()
        let cloud = services.cloud
        let resolver = ResumeLinkResolver()
        let session = CloudMachineSession(machine: CloudMachine(id: "early-provider-failure", status: .running),
            appLink: CloudLinkSession(key: CloudLinkKey(machine: "early-provider-failure"), resolver: resolver),
            localIdentity: { nil }, mainWork: services.mainWork)
        services.machines.add(session)
        defer { cloud.changes.stop(); session.disconnect() }
        let failed = CloudMachine(id: session.machineID, status: .running,
            lastChangeFailure: .init(code: "pause_failed", message: "provider refused"))
        session.connect()
        await resolver.waitForOpen()
        try await cloud.changes.run(.pausing, machineID: session.machineID, of: { session }) {
            await resolver.release()
            for await phase in ObservationStream({ session.linkPhase }) where phase == .idle { break }
            cloud.apply(failed, to: session, read: cloud.beginRecordRead(machineID: session.machineID))
            #expect(session.machine.pendingChange == .pausing)
            #expect(session.machine.lastChangeFailure == failed.lastChangeFailure)
            #expect(await resolver.attempts == 1)
        }
        // The error was already displayed; settling its mutation must still authorize recovery.
        cloud.apply(failed, to: session, read: cloud.beginRecordRead(machineID: session.machineID))
        #expect(session.machine.pendingChange == nil)
        await resolver.waitForAttempts(2)
        #expect(await resolver.attempts == 2)
    }

    @Test func aStaleProviderFailureCannotRetireANewerMutation() async throws {
        let session = Self.session(status: .running)
        let changes = CloudMachineChanges()
        defer { changes.stop(); session.disconnect() }
        changes.readIssued(1)
        try await changes.run(.pausing, machineID: session.machineID, of: { session }) {}
        let mutationID = session.machine.pendingMutationID
        let failure = CloudMachine(id: session.machineID, status: .running,
            lastChangeFailure: .init(code: "pause_failed", message: "provider refused"))
        let stale = changes.applyingPending(to: failure, read: 1)
        #expect(stale.pendingMutationID == mutationID)
        #expect(stale.failedMutationID == nil)
        let confirmed = changes.applyingPending(to: failure, read: 2)
        #expect(confirmed.pendingMutationID == nil)
        #expect(confirmed.failedMutationID == mutationID)
    }

    @Test func aProviderKillFailureDoesNotRetireAnOlderPause() async throws {
        let session = Self.session(status: .running)
        let changes = CloudMachineChanges()
        defer { changes.stop(); session.disconnect() }
        try await changes.run(.pausing, machineID: session.machineID, of: { session }) {}
        let pauseID = session.machine.pendingMutationID
        try await changes.run(.deleting, machineID: session.machineID, of: { session }) {}
        let failure = CloudMachine(id: session.machineID, status: .running,
            lastChangeFailure: .init(code: "delete_failed", message: "provider refused"))
        let restored = changes.applyingPending(to: failure)
        #expect(restored.pendingMutationID == pauseID)
        #expect(restored.shownStatus == .pausing)
        #expect(changes.applyingPending(to: failure).pendingMutationID == pauseID,
                "inspecting the same provider error twice cannot retire the older pause")
        #expect(changes.pendingStatus(for: CloudMachine(id: session.machineID, status: .paused)) == nil)
    }

    @Test func anAcceptedMutationSurvivesAStaleListUntilItsTerminalRecord() async throws {
        let session = Self.session(status: .running)
        let changes = CloudMachineChanges(sleep: { _ in })
        try await changes.run(.pausing, machineID: session.machineID, of: { session }) {}

        let stale = CloudMachine(id: session.machineID, status: .running)
        #expect(changes.pendingStatus(for: stale) == .pausing)
        #expect(changes.pendingStatus(for: CloudMachine(id: session.machineID, status: .paused)) == nil)
        session.disconnect()
    }

    @Test func aLaterRunningRevisionRetiresAPauseSupersededElsewhere() async throws {
        let session = Self.session(status: .running)
        defer { session.disconnect() }
        let changes = CloudMachineChanges()
        defer { changes.stop() }
        // Read 1 was issued before this app's pause was accepted. It is a stale running
        // response and must keep the optimistic pause visible.
        changes.readIssued(1)
        try await changes.run(.pausing, machineID: session.machineID, of: { session }) {}
        let stale = changes.applyingPending(to: CloudMachine(id: session.machineID, status: .running), read: 1)
        #expect(stale.pendingChange == .pausing)
        // Read 2 is the authoritative later revision: another client paused then resumed
        // the machine before this app ever observed the paused record.
        let superseding = changes.applyingPending(to: CloudMachine(id: session.machineID, status: .running,
            updatedAt: Date(timeIntervalSince1970: 2)), read: 2)
        #expect(superseding.pendingChange == nil)
        #expect(changes.pendingStatus(for: CloudMachine(id: session.machineID, status: .running)) == nil)
    }

    @Test(arguments: [CloudMachine.Status.pausing, .starting])
    func appServerRevisionsRetireSupersededChangesAfterAcknowledgement(change: CloudMachine.Status) async throws {
        let session = Self.session(status: change == .pausing ? .running : .paused)
        defer { session.disconnect() }
        let status = change == .pausing ? "running" : "paused"
        // Decimal revisions exceed fixed-width integers; preserve their ordering losslessly.
        let baseline = try Self.next("{\"id\":\"\(session.machineID)\",\"status\":\"\(status)\",\"revision\":\"99999999999999999999\"}")
        session.machine = baseline
        let changes = CloudMachineChanges()
        defer { changes.stop() }
        changes.readIssued(1)
        try await changes.run(change, machineID: session.machineID, of: { session }) {}
        let newer = try Self.next("{\"id\":\"\(session.machineID)\",\"status\":\"\(status)\",\"revision\":\"100000000000000000000\"}")
        #expect(changes.applyingPending(to: newer, read: 1).pendingChange == change)
        #expect(changes.applyingPending(to: baseline, read: 2).pendingChange == change)
        #expect(changes.applyingPending(to: newer, read: 3).pendingChange == nil)
    }

    @Test(arguments: [CloudMachine.Status.pausing, .starting])
    func appServerTerminalRecordsWithoutUpdatedAtRespectReadOrdering(change: CloudMachine.Status) async throws {
        let services = MachineIconTests.services()
        let cloud = services.cloud
        let session = MachineIconTests.cloudMachine(services, id: "terminal-without-timestamp")
        defer { cloud.changes.stop(); session.disconnect() }
        session.machine.status = change == .pausing ? .running : .paused
        let target = change == .pausing ? "paused" : "running"
        let terminal = try Self.next("{\"id\":\"terminal-without-timestamp\",\"status\":\"\(target)\"}")
        #expect(terminal.updatedAt == nil)
        let staleRead = cloud.beginRecordRead(machineID: session.machineID)
        try await cloud.changes.run(change, machineID: session.machineID, of: { session }) {}
        cloud.apply(terminal, to: session, read: staleRead)
        #expect(session.machine.pendingChange == change, "pre-acknowledgement terminal reads cannot settle")
        cloud.changes.listed([session.machine], refresh: {})
        #expect(session.machine.pendingChange == change)
        #expect(cloud.changes.isSettling, "polling cannot bypass the read fence")
        cloud.apply(terminal, to: session, read: cloud.beginRecordRead(machineID: session.machineID))
        #expect(session.machine.pendingChange == nil, "fresh matching terminal state needs no timestamp")
        cloud.changes.listed([session.machine], refresh: {})
        #expect(!cloud.changes.isSettling)
    }

    @Test func aResumeRefreshFailureKeepsTheRawPausedRecord() async {
        let session = Self.session(status: .paused)
        session.resumer = { [session] _ in
            // CloudService's accepted resume leaves this optimistic status until a list settles it.
            session.machine.pendingChange = .starting
        }
        session.attach()
        for await resuming in ObservationStream({ session.resuming }) where !resuming { break }
        #expect(session.machine.status == .paused)
        session.disconnect()
    }

    @Test(arguments: [CloudMachine.Status.pausing, .starting, .deleting])
    func aStatusReadPreservesThePendingPowerMutation(change: CloudMachine.Status) async throws {
        let services = MachineIconTests.services()
        let cloud = services.cloud
        let session = MachineIconTests.cloudMachine(services, id: "status-during-mutation")
        defer { session.disconnect() }
        session.machine.status = change == .starting ? .paused : .running
        var stale = session.machine
        stale.displayName = "Updated by status read"
        AppActions.bind(services)
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: session.machineID), origin: .user)
        let read = cloud.beginRecordRead(machineID: session.machineID)
        try await cloud.changes.run(change, machineID: session.machineID, of: { session }) {
            cloud.apply(stale, to: session, read: read)
            for id: ActionID in ["cloudPauseMachine", "cloudResumeMachine", "cloudKillMachine"] {
                #expect(services.registry.action(for: id)?.targetUnavailableReason?(invocation) == CloudStrings.machineChanging(change))
            }
            #expect(session.machine.pendingChange == change)
            #expect(session.machine.shownStatus == change)
            #expect(session.machine.displayName == stale.displayName)
            #expect(!CloudHandlers.attachable(session))
        }
        // An acknowledged request still waits for the provider's terminal record.
        cloud.apply(stale, to: session, read: cloud.beginRecordRead(machineID: session.machineID))
        #expect(session.machine.pendingChange == change)
        #expect(!CloudHandlers.attachable(session))
        cloud.changes.stop()
    }

    // MARK: The record

    @Test func everyBackendStatusKeepsItsOwnState() throws {
        let expected: [String: CloudMachine.Status] = [
            "provisioning": .provisioning, "starting": .starting, "running": .running, "pausing": .pausing,
            "paused": .paused, "deleting": .deleting, "failed": .failed, "rebooting": .unknown,
        ]
        for (wire, status) in expected {
            #expect(try Self.next(#"{"id":"vm_1","status":"\#(wire)"}"#).status == status, "\(wire)")
        }
    }

    @Test func onlyTheInBetweenStatesAreChanging() {
        for status: CloudMachine.Status in [.pausing, .starting, .deleting] { #expect(status.isChanging, "\(status)") }
        for status: CloudMachine.Status in [.provisioning, .running, .paused, .failed, .destroyed, .unknown] {
            #expect(!status.isChanging, "\(status)")
        }
        // A machine starting again is on its way up, as before; one pausing or deleting is not.
        #expect(CloudMachine.Status.starting.isLive)
        #expect(!CloudMachine.Status.pausing.isLive)
        #expect(!CloudMachine.Status.deleting.isLive)
    }

    @Test func thePauseReasonIsReadAsTheBackendSpellsIt() throws {
        #expect(try Self.next(#"{"id":"vm_1","status":"paused","pause_reason":"idle"}"#).pauseReason == .idle)
        // The cost backstop is cmux's own idle pause too: an attach resumes it.
        #expect(try Self.next(#"{"id":"vm_1","status":"paused","pause_reason":"no_report"}"#).pauseReason == .idle)
        #expect(try Self.next(#"{"id":"vm_1","status":"paused","pause_reason":"provider_stopped"}"#).pauseReason == nil)
        #expect(try Self.next(#"{"id":"vm_1","status":"paused","pause_reason":null}"#).pauseReason == nil)
        // An older app server's camel case still reads.
        #expect(try Self.next(#"{"id":"vm_1","status":"paused","pauseReason":"idle"}"#).pauseReason == .idle)
        #expect(try Self.next(#"{"id":"vm_1","status":"paused"}"#).pauseReason == nil)
    }

    @Test func theRecordsErrorIsTheLastChangesFailure() throws {
        let failed = try Self.next(#"{"id":"vm_1","status":"running","error":{"code":"cloud.provider.unavailable","message":"no capacity","at":1700000000000}}"#)
        let failure = try #require(failed.lastChangeFailure)
        #expect(failure.code == "cloud.provider.unavailable")
        #expect(failure.text == "no capacity")
        #expect(failure.at == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try Self.next(#"{"id":"vm_1","status":"running","error":null}"#).lastChangeFailure == nil)
        #expect(try Self.next(#"{"id":"vm_1","status":"running","error":"odd"}"#).lastChangeFailure == nil)
        #expect(try Self.next(#"{"id":"vm_1","status":"running","error":{"code":"x","message":""}}"#).lastChangeFailure?.text == "x")
        // The `/api/vm` record decodes the same fields.
        let decoded = try JSONDecoder().decode(CloudMachine.self, from: Data(#"{"id":"vm-1","status":"pausing","error":{"code":"x","message":"y"}}"#.utf8))
        #expect(decoded.status == .pausing)
        #expect(decoded.lastChangeFailure?.text == "y")
    }

    // MARK: The stage

    @Test func aChangeOnItsWayReadsAsItselfNotAsWhereItGoes() {
        // Still connected and loaded: a pausing machine reads Pausing…, not Ready or Paused.
        let pausing = CloudMachineStageInput(machineStatus: .pausing, link: .up, daemonConnected: true, daemonLoaded: true).stage
        #expect(pausing == .pausing)
        #expect(pausing != .paused(idle: false))
        #expect(CloudMachineStageInput(machineStatus: .deleting).stage == .deleting)
        #expect(CloudMachineStageInput(machineStatus: .starting).stage == .resuming)
        // A resumed machine whose daemon already loaded is ready, whatever the record says.
        #expect(CloudMachineStageInput(machineStatus: .starting, link: .up, daemonConnected: true, daemonLoaded: true).stage == .ready)
        for stage: CloudMachineStage in [.pausing, .resuming, .deleting] {
            #expect(stage.isChanging)
            #expect(!stage.isFinished, "a change on its way is not done")
            #expect(!stage.isPaused)
            #expect(stage.failure == nil)
        }
        #expect([CloudMachineStage.pausing, .resuming, .deleting].map(\.name) == ["pausing", "resuming", "deleting"])
        #expect(CloudStrings.stage(.pausing) == "Pausing…")
        #expect(CloudStrings.stage(.resuming) == "Resuming…")
        #expect(CloudStrings.stage(.deleting) == "Deleting…")
    }

    @Test func aFailedMachineSaysTheRecordsReason() {
        #expect(CloudMachineStageInput(machineStatus: .failed, changeFailure: "the VM is gone").stage == .failed("the VM is gone"))
        #expect(CloudMachineStageInput(machineStatus: .failed).stage == .failed(CloudStrings.machineFailed))
    }

    // MARK: The sidebar

    @Test func theHeaderSaysTheChangeAndNeedsNoAttention() {
        let expected: [(CloudMachine.Status, SidebarMachine.Status, String)] = [
            (.pausing, .pausing, "Pausing…"), (.starting, .resuming, "Resuming…"), (.deleting, .deleting, "Deleting…"),
        ]
        for (record, header, words) in expected {
            let session = Self.session(status: record)
            let machine = CloudCreationRows.machine(session, compatibility: nil, updates: DaemonUpdateBoard())
            #expect(machine.status == header, "\(record)")
            #expect(!machine.status.needsAttention)
            #expect(SectionHeaderRowView.statusText(machine.status, hostGroup: false) == words)
            #expect(SectionHeaderRowView.statusWords(machine.status) == words)
            #expect(Strings.attentionStatus(machine.status) == words)
            #expect(WorkspaceHoverCardContent.connectionTone(machine.status) == .attention)
            session.disconnect()
        }
    }

    @Test func aFailedChangeShowsOnTheHeader() {
        let session = Self.session(status: .paused)
        session.machine.lastChangeFailure = .init(code: "cloud.provider.unavailable", message: "no capacity")
        let header = CloudCreationRows.machine(session, compatibility: nil, updates: DaemonUpdateBoard())
        #expect(header.status == .paused, "the machine went back to paused")
        #expect(header.detail?.contains(CloudStrings.changeFailed("no capacity")) == true)
        session.machine.lastChangeFailure = nil
        #expect(CloudCreationRows.machine(session, compatibility: nil, updates: DaemonUpdateBoard()).detail == nil)
        session.disconnect()
    }

    // MARK: From the click

    @Test func aChangeShowsFromTheClickAndAFailedCallPutsTheRecordBack() async throws {
        let session = Self.session(status: .running)
        try await CloudMachineChanges.run(.pausing, of: { session }) {
            #expect(session.effectiveStatus == .pausing)
            #expect(session.stage == .pausing)
        }
        #expect(session.machine.pendingChange == .pausing, "shown until the next list replaces the record")
        // The next list's record replaces the shown change.
        session.machine = CloudMachine(id: session.machineID, status: .pausing)
        #expect(session.machine.pendingChange == nil)

        session.machine.status = .paused
        await #expect(throws: ActionFailure.self) {
            try await CloudMachineChanges.run(.starting, of: { session }) { throw ActionFailure(message: "quota") }
        }
        #expect(session.machine.pendingChange == nil)
        #expect(session.effectiveStatus == .paused)

        // A Kill sent while a resume waited: the resume's failure leaves Deleting… shown.
        await #expect(throws: ActionFailure.self) {
            try await CloudMachineChanges.run(.starting, of: { session }) {
                session.machine.pendingChange = .deleting
                throw ActionFailure(message: "quota")
            }
        }
        #expect(session.machine.pendingChange == .deleting)
        // A Resume shown from the click does not resume it a second time through an attach.
        session.machine.status = .paused
        session.machine.pendingChange = .starting
        session.resumer = { _ in }
        session.attach()
        #expect(!session.resuming)
        session.disconnect()
    }

    @Test func aKillTheServerTookReadsDeletingAndTheListIsReadSoon() {
        let session = Self.session(status: .running)
        // CloudService.deleteMachine once the server took the Kill.
        session.retainForDeleteTransition()
        #expect(session.stage == .deleting)
        #expect(CloudCreationRows.machine(session, compatibility: nil, updates: DaemonUpdateBoard()).status == .deleting)
        #expect(!session.isPermanentlyDisconnected)
        // A provider failure can put the record back to running. The retained session must still
        // be connectable; only a list omission permanently disconnects it.
        session.machine.status = .running
        session.connect()
        session.disconnect()
        let changes = CloudMachineChanges()
        changes.began {}
        #expect(changes.isSettling, "the list is read again soon")
        changes.stop()
        #expect(!changes.isSettling)
    }

    @Test func theListIsReadAgainOnlyWhileAMachineChanges() {
        let changes = CloudMachineChanges()
        changes.listed([CloudMachine(id: "vm-1", status: .running), CloudMachine(id: "vm-2", status: .paused)]) {}
        #expect(!changes.isSettling)
        changes.listed([CloudMachine(id: "vm-1", status: .pausing)]) {}
        #expect(changes.isSettling)
        changes.stop()
        #expect(!changes.isSettling)
        // A list read on its way when the service stopped lands after: it schedules nothing.
        changes.listed([CloudMachine(id: "vm-1", status: .pausing)]) {}
        changes.began {}
        #expect(!changes.isSettling, "stopped")
        changes.start()
        changes.listed([CloudMachine(id: "vm-1", status: .pausing)]) {}
        #expect(changes.isSettling, "started again")
        changes.stop()
    }

    @Test func aFailedMachineSaysTheRecordsErrorOnce() {
        let session = Self.session(status: .failed)
        session.machine.lastChangeFailure = .init(code: "cloud.provider.unavailable", message: "no capacity")
        let header = CloudCreationRows.machine(session, compatibility: nil, updates: DaemonUpdateBoard())
        #expect(header.detail?.components(separatedBy: "no capacity").count ?? 0 <= 2, "the reason is not repeated")
        session.disconnect()
    }

    // MARK: Power actions wait

    @Test func pauseResumeAndKillWaitForAChangeOnItsWay() {
        for status: CloudMachine.Status in [.pausing, .starting, .deleting] {
            #expect(status.blocks(.pause), "\(status)")
            #expect(status.blocks(.resume), "\(status)")
            #expect(CloudStrings.machineChanging(status) != nil, "\(status)")
        }
        #expect(CloudMachine.Status.pausing.blocks(.kill))
        #expect(CloudMachine.Status.starting.blocks(.kill))
        #expect(CloudMachine.Status.deleting.blocks(.kill))
        for status: CloudMachine.Status in [.running, .paused, .failed, .provisioning, .unknown] {
            for action: CloudMachine.PowerAction in [.pause, .resume, .kill] { #expect(!status.blocks(action), "\(action) \(status)") }
            #expect(CloudStrings.machineChanging(status) == nil)
        }
    }

    @Test func theBoundActionsCarryTheWait() {
        let services = MachineIconTests.services()
        AppActions.bind(services)
        let session = MachineIconTests.cloudMachine(services, id: "vm-gate-\(UUID().uuidString.prefix(8))")
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: session.machineID), origin: .user)
        func reason(_ id: ActionID) -> String? { services.registry.action(for: id)?.targetUnavailableReason?(invocation) }
        session.machine.status = .pausing
        #expect(reason("cloudPauseMachine") == CloudStrings.machineChanging(.pausing))
        #expect(reason("cloudResumeMachine") == CloudStrings.machineChanging(.pausing))
        #expect(reason("cloudKillMachine") == CloudStrings.machineChanging(.pausing))
        session.machine.status = .deleting
        #expect(reason("cloudKillMachine") == CloudStrings.machineChanging(.deleting))
        session.disconnect()
    }
}
