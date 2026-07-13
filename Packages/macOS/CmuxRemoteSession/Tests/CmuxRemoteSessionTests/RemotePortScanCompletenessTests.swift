import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Remote port scan per-TTY completeness")
struct RemotePortScanCompletenessTests {
    @Test("Unscoped fallback ports age out without becoming TTY-owned protection")
    func fallbackTransitionDoesNotFabricateTTYOwnership() {
        let panel = UUID()
        let completeOutput = "\(RemoteSessionCoordinator.remoteTTYPortScanCompleteMarker)\tttys010\n"
        let runner = SpyProcessRunner(
            result: RemoteCommandResult(status: 0, stdout: completeOutput, stderr: "")
        )
        let host = RecordingRemoteSessionHost()
        let coordinator = RemotePortScanGatingTests.makeCoordinator(runner: runner, host: host)

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.remotePortPollState.apply(
                observedPorts: [8080],
                mode: .hostWide,
                completeness: .complete
            )
            coordinator.updateRemotePortScanTTYsLocked([panel: "ttys010"])
            for _ in 0..<3 {
                coordinator.performRemotePortScanLocked()
            }
        }

        let generatedCommands = runner.requests.flatMap(\.arguments)
        #expect(generatedCommands.contains(where: { $0.contains("ttys010:8080") }) == false)
        #expect(host.detectedPortsByPanel[panel]?.isEmpty == true)
        #expect(host.detectedPorts.isEmpty)
        #expect(coordinator.queue.sync { coordinator.keepPolledRemotePortsUntilTTYScan } == false)
        coordinator.stop()
    }

    @Test("A healthy TTY ages out its missing port while an incomplete sibling retains its port")
    func mixedTTYCompletenessReconcilesIndependently() {
        let healthyPanel = UUID()
        let incompletePanel = UUID()
        let initialOutput = """
        ttys010\t4200
        ttys011\t5173
        \(RemoteSessionCoordinator.remoteTTYPortScanCompleteMarker)\tttys010
        \(RemoteSessionCoordinator.remoteTTYPortScanCompleteMarker)\tttys011
        """
        let mixedOutput = "\(RemoteSessionCoordinator.remoteTTYPortScanCompleteMarker)\tttys010\n"
        let runner = SpyProcessRunner(results: [
            RemoteCommandResult(status: 0, stdout: initialOutput, stderr: ""),
            RemoteCommandResult(status: 0, stdout: mixedOutput, stderr: ""),
        ])
        let host = RecordingRemoteSessionHost()
        let coordinator = RemotePortScanGatingTests.makeCoordinator(runner: runner, host: host)

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.updateRemotePortScanTTYsLocked([
                healthyPanel: "ttys010",
                incompletePanel: "ttys011",
            ])
            coordinator.performRemotePortScanLocked()
            for _ in 0...2 {
                coordinator.performRemotePortScanLocked()
            }
        }

        #expect(host.detectedPortsByPanel[healthyPanel]?.isEmpty == true)
        #expect(host.detectedPortsByPanel[incompletePanel] == [5173])
        #expect(host.detectedPorts == [5173])
        coordinator.stop()
    }
}
