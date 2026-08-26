struct BrowserPageMetadataDNSQuery {
    let host: String
    var continuation: CheckedContinuation<[BrowserPageMetadataResolvedAddress], Never>?
    var isRunning = false
}
