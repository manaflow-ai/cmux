/// Off-main input for resolving one immutable action catalog. Filesystem reads
/// happen in the killable helper before JSON decoding populates this value.
struct CmuxConfigActionCatalogSource: Sendable {
    let localPath: String?
    let local: ParsedConfig?
    let global: ParsedConfig
    let fingerprint: String
}
