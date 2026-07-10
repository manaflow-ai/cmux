import Foundation

struct TerminalPortalHostAuthority {
    let hostId: ObjectIdentifier
    let paneId: UUID
    let ownershipGeneration: UInt64
    let phase: TerminalPortalHostAuthorityPhase
}
