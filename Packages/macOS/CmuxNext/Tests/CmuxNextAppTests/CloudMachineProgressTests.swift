import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Observation
import Synchronization
import Testing
@testable import CmuxNextApp

/// cx-lu8f (ffrt1-v1, Lawrence 2026-10-09: "new cloud machine doesnt seem to
/// work for me ... it worked after a while, so it was confusing in terms of
/// loading state"). New Cloud Workspace left focus where it was, the machine
/// showed "provisioning" after its daemon connected, and the ~10 s until the
/// terminal showed no progress. From the click, the person must see where the
/// machine is and what happens next.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CloudMachineProgressTests {
    nonisolated final class FakeResolver: CloudLinkResolver {
        let socket: String
        init(socket: String) { self.socket = socket }
        func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
            CloudLinkSocket(key: key, path: socket, generation: 1)
        }
        func close(_ key: CloudLinkKey) async {}
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(10), until done: @escaping @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !done() {
            guard clock.now < deadline else { throw DaemonError.timedOut(what) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func session(_ machine: CloudMachine, socket: String) throws -> CloudMachineSession {
        let local = try CloudMachineSessionLinkTests.identity(generation: "g0", registry: "local")
        return CloudMachineSession(machine: machine, appLink: CloudLinkSession(key: CloudLinkKey(machine: machine.id),
                                                                                resolver: FakeResolver(socket: socket)),
                                   localIdentity: { local })
    }

    // MARK: Stages from real events

    @Test func theRequestStagesComeFromTheCreateCall() {
        #expect(CloudMachineStageInput(creation: .requesting).stage == .requesting)
        #expect(CloudMachineStageInput(creation: .creating).stage == .creating)
        #expect(CloudMachineStageInput(creation: .failed("quota exceeded")).stage == .failed("quota exceeded"))
        // The VM exists; its link has not answered yet.
        #expect(CloudMachineStageInput(creation: .created, machineStatus: .provisioning).stage == .booting)
        #expect(CloudMachineStageInput(creation: .created, link: .starting).stage == .booting)
        #expect(CloudMachineStageInput(creation: .created, link: .up).stage == .connecting)
        #expect(CloudMachineStageInput(creation: .created, link: .up, daemonConnected: true, daemonLoaded: true).stage == .ready)
    }

    /// The daemon's first-connect deadline is 10 s, about as long as a new
    /// VM's link takes to start: a link that is still starting is booting,
    /// never a failure (the old app showed "not connected" and then worked).
    @Test func aLinkStillStartingIsBootingAfterTheDaemonDeadline() {
        let input = CloudMachineStageInput(creation: .created, link: .starting, daemonFailure: "timed out")
        #expect(input.stage == .booting)
        // Behind a live link, a deadline with no failed attempt still connects.
        #expect(CloudMachineStageInput(creation: .created, link: .up).stage == .connecting)
    }

    @Test func aFailureCarriesItsReason() {
        #expect(CloudMachineStageInput(creation: .created, link: .failed("remote connect exited: no route"),
                                       daemonFailure: "no route").stage == .failed("remote connect exited: no route"))
        #expect(CloudMachineStageInput(creation: .created, link: .up, daemonFailure: "protocol mismatch").stage
            == .failed("protocol mismatch"))
        #expect(CloudMachineStageInput(creation: .created, link: .idle, linkEnded: "Disconnected").stage == .failed("Disconnected"))
        // One failed link start is retried by the daemon: booting until it gives up.
        #expect(CloudMachineStageInput(creation: .created, link: .failed("exited")).stage == .booting)
        #expect(CloudMachineStage.failed("x").isFinished && CloudMachineStage.ready.isFinished && !CloudMachineStage.booting.isFinished)
    }

    // MARK: Status equals the link

    /// A create response has no status, so the record said "provisioning" for
    /// as long as no list refresh came: cloud.machines and the sidebar said
    /// provisioning while the terminal worked. A connected daemon is running.
    @Test func aConnectedMachineIsRunningNotProvisioning() async throws {
        let server = try ScriptedDaemonSocket(handler: CloudMachineSessionLinkTests.daemon())
        defer { server.stop() }
        let created = try JSONDecoder().decode(CloudMachine.self, from: Data(#"{"id":"vm-new","provider":"freestyle"}"#.utf8))
        #expect(created.status == .provisioning)
        let session = try session(created, socket: server.path)
        defer { session.disconnect() }
        #expect(session.linkPhase == .idle)
        #expect(session.stage == .booting)
        session.connect()
        try await waitUntil("connected and loaded") { session.daemon.store.isLoaded && session.daemon.connection != nil }
        #expect(session.linkPhase == .up)
        #expect(session.stage == .ready)
        #expect(session.effectiveStatus == .running, "a connected daemon is a running machine, not provisioning")
        #expect(session.machine.status == .provisioning, "the API record is not rewritten")
    }

    // MARK: The flow: focus at once, then the terminal by itself

    /// The click puts the creation in the window at once (before any await):
    /// the window shows its progress and the sidebar selects its row. When
    /// the machine's daemon is ready, its workspace opens by itself and the
    /// creation leaves once that workspace is mirrored.
    @Test func newCloudWorkspaceShowsProgressAtOnceAndOpensTheTerminalWhenReady() async throws {
        let server = try ScriptedDaemonSocket(handler: CloudMachineSessionLinkTests.daemon())
        defer { server.stop() }
        let creations = CloudCreations()
        let window = WindowState(id: "w1", workspaceID: "local-ws")
        let gate = CloudTestGate()
        let made = Mutex<CloudMachineSession?>(nil)
        let opened = Mutex<[String]>([])
        let flow = CloudCreationFlow(
            creations: creations,
            create: { creation in
                creation.note(.creating)
                await gate.wait()
                let session = try self.session(CloudMachine(id: "vm-1", status: .provisioning), socket: server.path)
                made.withLock { $0 = session }
                session.connect()
                return session
            },
            open: { session in
                #expect(session.stage == .ready, "the workspace opens only when the daemon is ready")
                return "ws-cloud"
            },
            show: { id, _ in opened.withLock { $0.append(id) } }
        )
        let creation = flow.start(in: window, existing: nil)
        // Synchronous: no await between the click and these.
        #expect(window.cloudCreation == creation.id, "the window shows the new creation at once")
        #expect(creations.all.map(\.id) == [creation.id])
        #expect(creation.stage == .requesting || creation.stage == .creating)
        try await waitUntil("creating stage") { creation.stage == .creating }
        gate.open()
        try await waitUntil("ready") { opened.withLock { $0 } == ["ws-cloud"] }
        #expect(creation.stage == .ready)
        #expect(creation.workspaceID == "ws-cloud")
        #expect(creation.readyAfter != nil, "time to ready is recorded")
        made.withLock { $0 }?.disconnect()
    }

    @Test func aCreateFailureShowsTheReasonAndRetryRunsItAgain() async throws {
        let creations = CloudCreations()
        let window = WindowState(id: "w1")
        let attempts = Mutex(0)
        let flow = CloudCreationFlow(
            creations: creations,
            create: { creation in
                creation.note(.creating)
                let attempt = attempts.withLock { $0 += 1; return $0 }
                if attempt == 1 { throw ActionFailure(message: "Machine quota reached") }
                throw ActionFailure(message: "still no quota")
            },
            open: { _ in "unused" },
            show: { _, _ in }
        )
        let creation = flow.start(in: window, existing: nil)
        try await waitUntil("failed") { creation.stage.failure != nil }
        #expect(creation.stage.failure?.contains("Machine quota reached") == true)
        #expect(window.cloudCreation == creation.id, "the failure stays in the window with its reason")
        flow.retry(creation)
        try await waitUntil("second failure") { creation.stage.failure?.contains("still no quota") == true }
        #expect(attempts.withLock { $0 } == 2)
        flow.dismiss(creation, in: window)
        #expect(creations.all.isEmpty)
        #expect(window.cloudCreation == nil)
    }

    // MARK: The sidebar row

    /// The creation has a selectable row at once, in the one list too (an
    /// empty connecting machine shows nothing there), with a progress bar.
    @Test func theCreationHasASelectableRowAtOnce() throws {
        let creations = CloudCreations()
        let creation = creations.begin(window: "w1")
        let sections = SidebarBridge.addingCreations(creations.shown(in: "w1"), to: [
            SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("a"), title: "a"))]),
        ])
        let row = try #require(sections.flatMap(\.workspaces).first { $0.id.rawValue == creation.rowID })
        #expect(row.rowState != .placeholder, "the row is selectable")
        #expect(row.progress != nil, "the row shows progress")
        #expect(row.status == CloudStrings.stage(.requesting))
        var options = SidebarLayoutOptions()
        options.flattensMachines = true
        options.showsSoleMachineHeader = true
        let keys = SidebarLayout.make(sections: sections, metrics: .standard, options: options).rows.map(\.key)
        #expect(keys.contains(.workspace(WorkspaceID(creation.rowID))), "the one list shows the row")
        #expect(SidebarNavigation.selectedItem(page: nil, workspace: "a", creationRow: creation.rowID, layout: SidebarLayoutDocument(sections: []))
            == .workspace(WorkspaceID(creation.rowID)), "the window selects the creation's row")
        #expect(creations.shown(in: "w2").isEmpty, "another window does not list it")
    }
}
