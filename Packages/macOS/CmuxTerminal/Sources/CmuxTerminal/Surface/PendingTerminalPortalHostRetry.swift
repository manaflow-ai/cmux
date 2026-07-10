import Foundation

struct PendingTerminalPortalHostRetry {
    let hostId: ObjectIdentifier
    let ownershipGeneration: UInt64
    let retry: @MainActor () -> Void
}
