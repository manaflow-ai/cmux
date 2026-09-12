import Foundation

struct LinksPanelProjectionRequest: Hashable {
    let structuralRevision: UInt64
    let substringFilter: String
    let selectedHost: String?
    let selectedSourcePanelID: UUID?
}
