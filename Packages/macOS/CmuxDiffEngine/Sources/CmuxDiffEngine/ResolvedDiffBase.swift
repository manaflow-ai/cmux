/// Internal concrete baseline used by the Git snapshot loader.
struct ResolvedDiffBase: Sendable, Equatable {
    let info: DiffBaseInfo
    let object: String
}
