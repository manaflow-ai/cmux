import Foundation

/// Versioned immutable catalog captured by `palette.list`. Exact runs compare
/// this identity with a freshly loaded catalog before dispatching.
struct CmuxConfigActionCatalogSnapshot: Sendable {
    let id: UUID
    let cacheKey: String
    let sourceFingerprint: String
    let catalog: CmuxConfigActionCatalog
}
