internal import CmuxMobileRPC
internal import Foundation

extension MobileShellComposite {
    enum WorkspaceCreatePostResponseDisposition: Equatable {
        case apply
        case preserveSuccess
        case failClosed
    }

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

        /// Settles a decoded host success without inviting an unsafe duplicate.
        static func postResponseDisposition(
            operationID: UUID?,
            isCancelled: Bool,
            isCurrent: Bool
        ) -> WorkspaceCreatePostResponseDisposition {
            guard isCancelled || !isCurrent else { return .apply }
            return operationID == nil ? .preserveSuccess : .failClosed
        }
    }
}
