import Foundation

/// Shared copy for drag feedback and rejected catalog/socket mutations.
enum SurfaceTransferRejection: Error, LocalizedError, Equatable, Sendable {
    case cloudMachineMismatch

    var errorDescription: String? { message }

    var message: String {
        String(
            localized: "surfaceDrop.cloudMachineMismatch",
            defaultValue: "Cloud workspaces can only hold terminals, browsers, and displays from their own Cloud machine. Open a local workspace and move the splits there."
        )
    }
}
