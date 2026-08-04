struct WordPathResolutionSnapshot: Equatable, Sendable {
    let workingDirectory: String
    let point: WordPathVisibleLineSnapshot?
    let quicklook: WordPathQuicklookSnapshot?
    let viewport: WordPathVisibleLineSnapshot?
}
