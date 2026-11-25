import CmuxNextCloud
import CmuxNextDaemon
import Testing

/// The record and connect rules a Cloud machine session follows (`CloudMachineSession.applyRecord`, `connect`), and the
/// untracked script resume of a typing prewarm (cmux#34974), moved out of the App for the arch ratchet.
@MainActor @Suite struct CloudMachineRecordEdgeTests {
    @MainActor final class Holder: CloudMachineHolder {
        var machine: CloudMachine
        init(_ machine: CloudMachine) { self.machine = machine }
    }

    @Test func aRecordEdgeSuspendsConnectsOrRetries() {
        let paused = CloudMachine(id: "vm_a", status: .paused), running = CloudMachine(id: "vm_a", status: .running)
        #expect(paused.edge(from: .running, wasResuming: false, connected: true) == .suspend)
        #expect(running.edge(from: .paused, wasResuming: false, connected: false) == .connect)
        // A resume's overlay cleared over a record that already read running: a second live edge.
        #expect(running.edge(from: .running, wasResuming: true, connected: false) == .connect)
        #expect(running.edge(from: .running, wasResuming: true, connected: true) == nil)
        // A machine that ran after provisioning or starting answers only now.
        #expect(running.edge(from: .provisioning, wasResuming: false, connected: false) == .retry)
        #expect(running.edge(from: .starting, wasResuming: false, connected: false) == .retry)
        #expect(running.edge(from: .starting, wasResuming: false, connected: true) == nil)
        #expect(running.edge(from: .running, wasResuming: false, connected: false) == nil)
        #expect(paused.edge(from: .paused, wasResuming: false, connected: false) == nil)
    }

    @Test func onlyAPersonsAppLinkConnectRunsThroughStarting() {
        let starting = CloudMachine(id: "vm_a", status: .starting)
        #expect(!starting.holdsConnect(origin: .user, appLink: true), "a person's retry during a passive wake")
        #expect(starting.holdsConnect(origin: .script, appLink: true))
        #expect(starting.holdsConnect(origin: .user, appLink: false), "a legacy link keeps the strict hold")
        for status: CloudMachine.Status in [.pausing, .deleting] {
            #expect(CloudMachine(id: "vm_a", status: status).holdsConnect(origin: .user, appLink: true))
        }
        var resuming = CloudMachine(id: "vm_a", status: .paused)
        resuming.pendingChange = .starting
        #expect(!resuming.holdsConnect(origin: .user, appLink: true))
        #expect(!CloudMachine(id: "vm_a", status: .running).holdsConnect(origin: .script, appLink: true))
    }

    @Test func aScriptResumeShowsNoPendingChangeAndAPersonsDoes() async throws {
        let holder = Holder(CloudMachine(id: "vm_a", status: .paused))
        let changes = CloudMachineChanges()
        defer { changes.stop() }
        var rolledBack = 0
        try await changes.run(.starting, machineID: "vm_a", origin: .script, of: { holder }, onRollback: { _ in rolledBack += 1 }) {
            #expect(holder.machine.pendingChange == nil, "a typing hint publishes no overlay")
        }
        await #expect(throws: CloudAppOpFailure.self) {
            try await changes.run(.starting, machineID: "vm_a", origin: .script, of: { holder }, onRollback: { _ in rolledBack += 1 }) {
                throw CloudAppOpFailure(code: "cmux.cloud.refused", message: "")
            }
        }
        #expect(holder.machine.pendingChange == nil && rolledBack == 0, "a refused hint leaves the machine retryable")
        try await changes.run(.starting, machineID: "vm_a", origin: .user, of: { holder }) {
            #expect(holder.machine.pendingChange == .starting)
        }
        #expect(changes.pendingStatus(for: holder.machine) == .starting)
    }
}
