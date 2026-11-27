import CmuxFoundation

/// Keeps census identities attached to its immutable projection for later enrichment.
struct CmuxTopProcessCapture: Sendable {
    let listing: DarwinProcessListing
    let snapshot: CmuxTopProcessSnapshot
    let fields: CmuxTopProcessFields
}
