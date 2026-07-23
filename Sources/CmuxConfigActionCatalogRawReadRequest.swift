struct CmuxConfigActionCatalogRawReadRequest: Sendable, Equatable {
    let directory: String?
    let globalConfigPath: String
    let maximumConfigBytes: Int
}
