internal import CmuxMobileRPC
internal import Foundation

extension MobileShellComposite {
    /// Exact remote target captured before a workspace-create request suspends.
    struct WorkspaceCreatePinnedContext {
        let macDeviceID: String?
        let client: MobileCoreRPCClient
        let generation: UUID
        let supportedHostCapabilities: Set<String>
        let hostDisplayName: String

        /// Whether the caller still exposes the same Mac, client, and generation.
        func isCurrent(
            macDeviceID currentMacDeviceID: String?,
            client currentClient: MobileCoreRPCClient?,
            generation currentGeneration: UUID
        ) -> Bool {
            macDeviceID == currentMacDeviceID
                && client === currentClient
                && generation == currentGeneration
        }
    }
}
