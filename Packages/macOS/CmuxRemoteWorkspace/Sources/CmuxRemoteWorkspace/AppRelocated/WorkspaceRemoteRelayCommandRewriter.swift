import CmuxRemoteWorkspace
import Foundation

/// App-side conformance to the relay's command-rewrite seam: forwards to the
/// package-owned alias-aware rewrite so the relay server never imports
/// `Workspace`.
struct WorkspaceRemoteRelayCommandRewriter: RemoteRelayCommandRewriting {
    func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        RemoteRelayCommandLineRewriter.rewrite(
            commandLine,
            workspaceAliases: workspaceAliases,
            surfaceAliases: surfaceAliases
        )
    }
}
