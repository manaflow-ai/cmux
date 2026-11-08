import Foundation

/// The host identity and model epoch currently authorized to present a terminal portal.
struct TerminalPortalHostAuthority {
    let hostId: ObjectIdentifier
    let paneId: UUID
    let instanceSerial: UInt64
    let ownershipGeneration: UInt64
}
