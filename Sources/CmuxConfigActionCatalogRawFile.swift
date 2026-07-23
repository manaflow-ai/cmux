import Foundation

struct CmuxConfigActionCatalogRawFile: Sendable, Equatable {
    let status: CmuxConfigActionCatalogRawFileStatus
    let data: Data
}
