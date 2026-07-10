#if os(iOS)
struct TranscriptMeasurementConfiguration: Hashable, Sendable {
    let widthBucket: Int
    let environment: TranscriptMeasurementEnvironment
}
#endif
