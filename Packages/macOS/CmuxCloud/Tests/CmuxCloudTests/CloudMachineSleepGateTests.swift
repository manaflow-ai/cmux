import Foundation
import Testing
@testable import CmuxCloud

@Suite("Cloud machine sleep gate")
struct CloudMachineSleepGateTests {
    private let machineID = "sleepy-vm"

    @Test("a poll that began before a local pause cannot restore running")
    func stalePollAfterLocalPauseIsRejected() async {
        let links = makeLinks()
        let beforePause = Date(timeIntervalSince1970: 100)
        await links.setMachineStatus("running", for: machineID, observedAt: beforePause)
        await links.recordLocalMachineStatus("paused", for: machineID)

        #expect(!(await links.setMachineStatus("running", for: machineID, observedAt: beforePause)))
        await expectUpkeepRetry(links)
    }

    @Test("a poll observed after a local pause can install running")
    func freshPollAfterLocalPauseIsAccepted() async {
        let links = makeLinks()
        await links.recordLocalMachineStatus("paused", for: machineID)

        #expect(await links.setMachineStatus("running", for: machineID, observedAt: Date().addingTimeInterval(1)))
        await #expect(throws: CloudMachineLinkManager.ManagerError.self) {
            try await CloudMachineLinkManager.$isBackgroundUpkeep.withValue(true) {
                try await links.connected(machineID: machineID)
            }
        }
    }

    @Test("a poll cannot tear down a user resume in flight")
    func pollDuringResumeIsRejected() async {
        let gate = ResumeGate()
        let links = makeLinks(resume: { id in
            await gate.started()
            await gate.wait()
            return "running"
        })
        await links.setMachineStatus("paused", for: machineID)
        let connect = Task { try? await links.connected(machineID: machineID) }
        await gate.waitUntilStarted()

        #expect(!(await links.setMachineStatus("paused", for: machineID, observedAt: Date().addingTimeInterval(1))))
        await gate.release()
        _ = await connect.value
    }

    @Test("upkeep refuses a paused machine without calling resume")
    func upkeepDoesNotResumePausedMachine() async {
        let calls = ResumeCalls()
        let links = makeLinks(resume: { id in
            await calls.add(id)
            return "running"
        })
        await links.setMachineStatus("paused", for: machineID)

        await #expect(throws: CloudMachineLinkManager.ManagerError.self) {
            try await CloudMachineLinkManager.$isBackgroundUpkeep.withValue(true) {
                try await links.connected(machineID: machineID)
            }
        }
        #expect(await calls.values.isEmpty)
    }

    @Test("an explicit connect resumes once and records the resumed state")
    func explicitConnectResumesOnce() async {
        let calls = ResumeCalls()
        let links = makeLinks(resume: { id in
            await calls.add(id)
            return "running"
        })
        await links.setMachineStatus("paused", for: machineID)

        _ = try? await links.connected(machineID: machineID)
        #expect(await calls.values == [machineID])
        await #expect(throws: CloudMachineLinkManager.ManagerError.self) {
            try await CloudMachineLinkManager.$isBackgroundUpkeep.withValue(true) {
                try await links.connected(machineID: machineID)
            }
        }
    }

    @Test("only explicit asleep states gate connects and stale facts are pruned")
    func asleepStatesAndPruning() async {
        #expect(CloudMachineLinkManager.isAsleepStatus("paused"))
        #expect(CloudMachineLinkManager.isAsleepStatus("pausing"))
        #expect(CloudMachineLinkManager.isAsleepStatus("stopped"))
        #expect(CloudMachineLinkManager.isAsleepStatus("suspended"))
        #expect(!CloudMachineLinkManager.isAsleepStatus("provisioning"))
        #expect(!CloudMachineLinkManager.isAsleepStatus("creating"))

        let links = makeLinks()
        await links.setPrivateAddresses(["10.0.0.7"], for: machineID)
        await links.setMachineStatus("paused", for: machineID)
        await links.retainAddresses(machineIDs: [])
        #expect(await links.privateAddresses(for: machineID).isEmpty)
        await #expect(throws: CloudMachineLinkManager.ManagerError.self) {
            try await CloudMachineLinkManager.$isBackgroundUpkeep.withValue(true) {
                try await links.connected(machineID: machineID)
            }
        }
    }

    private func makeLinks(
        resume: @escaping @Sendable (String) async -> String = { _ in "running" }
    ) -> CloudMachineLinkManager {
        CloudMachineLinkManager(
            clientURL: URL(fileURLWithPath: "/tmp/cmux-cloud-test-client"),
            resumeMachine: { id in await resume(id) },
            hostThemeColors: { nil }
        )
    }

    private func expectUpkeepRetry(_ links: CloudMachineLinkManager) async {
        await #expect(throws: CloudMachineLinkManager.ManagerError.self) {
            try await CloudMachineLinkManager.$isBackgroundUpkeep.withValue(true) {
                try await links.connected(machineID: machineID)
            }
        }
    }
}

private actor ResumeCalls {
    private(set) var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

private actor ResumeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var didStart = false

    func started() {
        didStart = true
    }

    func waitUntilStarted() async {
        while !didStart { await Task.yield() }
    }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
