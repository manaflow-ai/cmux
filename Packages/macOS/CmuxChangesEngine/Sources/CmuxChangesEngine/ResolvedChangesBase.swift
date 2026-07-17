/// The validated tree object and metadata used by one engine operation.
struct ResolvedChangesBase: Sendable {
    let diffRef: String
    let info: ChangesBaseInfo
}
