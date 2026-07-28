extension CmuxConfigActionCatalogProcessReader {
    struct LaunchSpecification: Sendable {
        let executablePath: String
        let arguments: [String]
        let environment: [String: String]
    }
}
