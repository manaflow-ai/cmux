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
        await expectNotRetryLater(links)
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

        await expectRetryLater(links)
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
        await expectNotRetryLater(links)
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
        await expectNotRetryLater(links)
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
        await expectRetryLater(links)
    }

    private func expectRetryLater(_ links: CloudMachineLinkManager) async {
        do {
            try await CloudMachineLinkManager.$isBackgroundUpkeep.withValue(true) {
                try await links.connected(machineID: machineID)
            }
            Issue.record("Expected the paused machine gate to reject upkeep")
        } catch let error as CloudMachineLinkManager.ManagerError {
            guard case .retryLater(let message) = error else {
                Issue.record("Expected retryLater from the paused machine gate, got \(error)")
                return
            }
            #expect(message.contains("waiting for it to run"))
        } catch {
            Issue.record("Expected retryLater from the paused machine gate, got \(error)")
        }
    }

    private func expectNotRetryLater(_ links: CloudMachineLinkManager) async {
        do {
            try await CloudMachineLinkManager.$isBackgroundUpkeep.withValue(true) {
                try await links.connected(machineID: machineID)
            }
        } catch let error as CloudMachineLinkManager.ManagerError {
            if case .retryLater = error {
                Issue.record("A non-paused machine was rejected by the paused machine gate")
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
    private var released = false

    func started() {
        didStart = true
    }

    func waitUntilStarted() async {
        while !didStart { await Task.yield() }
    }

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
