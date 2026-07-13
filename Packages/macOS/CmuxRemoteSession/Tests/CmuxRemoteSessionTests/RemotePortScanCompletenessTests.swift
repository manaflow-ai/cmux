import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Remote port scan per-TTY completeness")
struct RemotePortScanCompletenessTests {
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
