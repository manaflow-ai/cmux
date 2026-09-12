protocol BrowserPageMetadataResolving: Sendable {
    func addresses(for host: String) async -> [BrowserPageMetadataResolvedAddress]
}
