extension CmuxConfigActionCatalogSource {
    struct ParsedConfig: Sendable {
        let config: CmuxConfigFile?
        let issue: CmuxConfigIssue?
        let contentDigest: String
    }
}
