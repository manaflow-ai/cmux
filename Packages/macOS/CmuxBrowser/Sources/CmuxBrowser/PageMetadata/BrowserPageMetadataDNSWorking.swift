protocol BrowserPageMetadataDNSWorking: Sendable {
    func resolve(
        host: String,
        completion: @escaping @Sendable ([BrowserPageMetadataResolvedAddress]) -> Void
    )
}
