import Foundation

extension CmuxConfigActionCatalogProcessSession {
    enum Result: Sendable {
        case completed(Data?)
        case quarantined
    }
}
