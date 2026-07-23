import Foundation

struct CmuxConfigActionCatalogProcessQuarantineLease: Sendable, Equatable {
    let id: UUID
    let key: String
    let lane: CmuxConfigActionCatalogProcessQuarantineLane
}
