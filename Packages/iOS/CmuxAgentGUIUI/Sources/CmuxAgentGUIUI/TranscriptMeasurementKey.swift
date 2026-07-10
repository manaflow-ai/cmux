#if os(iOS)
struct TranscriptMeasurementKey: Hashable, Sendable {
    let contentHash: Int
    let widthBucket: Int
    let contentSizeCategory: String
    let userInterfaceStyle: Int
}
#endif
