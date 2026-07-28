protocol CmuxConfigActionCatalogRawReading: Sendable {
    func read(
        request: CmuxConfigActionCatalogRawReadRequest
    ) async -> CmuxConfigActionCatalogRawReadResponse?
}
