import CmuxRemoteWorkspace
import Foundation
@testable import CmuxRemoteSession

struct IntentionalCleanupRelayCommandRewriter: RemoteRelayCommandRewriting {
    func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data { commandLine }
}
