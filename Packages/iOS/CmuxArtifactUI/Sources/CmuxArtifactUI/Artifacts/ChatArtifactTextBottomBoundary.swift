/// One measured TextKit document end used by bottom-pin reconciliation.
struct ChatArtifactTextBottomBoundary: Equatable, Sendable {
    let storageEnd: Int
    let contentOffsetY: Double
}
