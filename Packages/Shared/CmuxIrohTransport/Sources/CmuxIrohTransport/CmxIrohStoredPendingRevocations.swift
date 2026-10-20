/// Versioned device-local storage envelope for one account's pending revocations.
struct CmxIrohStoredPendingRevocations: Codable, Equatable, Sendable {
    let version: Int
    let entries: [CmxIrohPendingRevocation]
}
