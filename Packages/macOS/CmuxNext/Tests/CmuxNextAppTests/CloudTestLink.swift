@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextWakeups
import Foundation

/// A Cloud machine session on the app server's link (``CloudLinkSession``) for tests: each
/// `cloud.machine.connect` answers `socket` (a stand-in path by default, which no connection
/// reaches) with `owns` as the link's owner answer. Tests that need a live daemon start it on
/// their own socket (`daemon.start(remote:)`) or pass that socket here.
@MainActor
enum CloudTestLink {
    static func session(id: String, status: CloudMachine.Status = .unknown, name: String, socket: String? = nil, owns: Bool = true,
                        mainWork: MainWorkScheduler = MainWorkScheduler(budget: MainFrameBudget())) -> CloudMachineSession {
        let resolver = SocketLinkResolver(path: socket ?? "/tmp/cn-test-link-\(id).sock", owns: owns)
        return CloudMachineSession(machine: CloudMachine(id: id, status: status, displayName: name),
                                   appLink: CloudLinkSession(key: CloudLinkKey(machine: id), resolver: resolver),
                                   localIdentity: { nil }, mainWork: mainWork)
    }
}

private struct SocketLinkResolver: CloudLinkResolver {
    let path: String
    let owns: Bool

    func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
        CloudLinkSocket(key: key, path: path, generation: 1, callerOwnsVM: owns)
    }

    func close(_ key: CloudLinkKey) async {}
}
