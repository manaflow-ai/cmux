struct CmuxConfigActionCatalogRawReadResponse: Sendable, Equatable {
    let localPath: String?
    let local: CmuxConfigActionCatalogRawFile?
    let global: CmuxConfigActionCatalogRawFile
}
