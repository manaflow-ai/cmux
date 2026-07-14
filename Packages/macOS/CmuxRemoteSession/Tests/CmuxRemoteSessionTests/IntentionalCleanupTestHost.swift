import CmuxCore
import CmuxRemoteWorkspace
import Foundation
@testable import CmuxRemoteSession

// Test-only lock protects results published from the coordinator queue.
final class IntentionalCleanupTestHost: RemoteSessionHosting, @unchecked Sendable {
    private let lock = NSLock()
    private var _persistentCleanupResults: [Bool] = []

    var persistentCleanupResults: [Bool] { lock.withLock { _persistentCleanupResults } }

    func publishConnectionState(_ state: WorkspaceRemoteConnectionState, detail: String?) {}
    func publishDaemonStatus(_ status: WorkspaceRemoteDaemonStatus) {}
    func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {}
    func publishPortsSnapshot(detectedByPanel: [UUID: [Int]], detected: [Int]) {}
    func publishHeartbeat(count: Int, lastSeenAt: Date?) {}
    func publishBootstrapRemoteTTY(_ ttyName: String) {}
    func publishPersistentCleanupResult(succeeded: Bool) {
        lock.withLock { _persistentCleanupResults.append(succeeded) }
    }
}
