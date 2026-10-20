import Foundation
@testable import CmuxNextCloud

@MainActor
final class CloudObservedAuthorityTestWorld {
    var identity = CloudSessionLifecycle.Identity(generation: 1, accountID: "stack_1")
    let owner = CloudTeamScopeWorld(wireTokens: true)
    let install: MacInstallIdentity
    let scopes: CloudTeamScope
    lazy var observed = CloudObservedAuthority(current: { [weak self] in self?.identity == $0 })

    init(root: URL) {
        let owner = owner
        install = MacInstallIdentity(store: .files(directory: root), transport: owner, deviceName: "Test Mac", clientVersion: "2.4.0")
        scopes = CloudTeamScope(identity: install, transport: owner, selection: { await owner.selection() },
            session: { NativeDeviceTestWorld.session() })
    }

    func snapshot() async throws -> CloudTeamScope.Snapshot {
        try await install.signedIn(stackUser: "stack_1", session: { "test-session" })
        return try await scopes.snapshot()
    }
}
