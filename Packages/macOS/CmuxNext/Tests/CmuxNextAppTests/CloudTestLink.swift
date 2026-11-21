@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextWakeups
import Foundation

/// A Cloud machine session on the app server's link (``CloudLinkSession``) for tests: each
/// `cloud.machine.connect` answers `socket` (a stand-in path by default, which no connection
/// reaches) with `owns` as the link's owner answer (and `teammate` as its teammate answer). Tests that need a live daemon start it on
/// their own socket (`daemon.start(remote:)`) or pass that socket here.
@MainActor
enum CloudTestLink {
    static func session(id: String, status: CloudMachine.Status = .unknown, name: String, socket: String? = nil, owns: Bool = true,
                        teammate: Bool = false, mainWork: MainWorkScheduler = MainWorkScheduler(budget: MainFrameBudget()),
                        opened: (@Sendable () throws -> Void)? = nil) -> CloudMachineSession {
        let resolver = SocketLinkResolver(path: socket ?? "/tmp/cn-test-link-\(id).sock", owns: owns, teammate: teammate, opened: opened)
        return CloudMachineSession(machine: CloudMachine(id: id, status: status, displayName: name),
                                   appLink: CloudLinkSession(key: CloudLinkKey(machine: id), resolver: resolver),
                                   localIdentity: { nil }, mainWork: mainWork)
    }
}

private struct SocketLinkResolver: CloudLinkResolver {
    let path: String
    let owns: Bool
    var teammate = false
    /// Runs at each connect (a test records it, or throws to fail the connect).
    var opened: (@Sendable () throws -> Void)?

    func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
        try opened?()
        return CloudLinkSocket(key: key, path: path, generation: 1, callerOwnsVM: owns, callerIsTeammate: teammate)
    }

    func close(_ key: CloudLinkKey) async {}
}
