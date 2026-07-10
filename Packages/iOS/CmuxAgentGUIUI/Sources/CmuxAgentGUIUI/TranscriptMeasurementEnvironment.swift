#if os(iOS)
struct TranscriptMeasurementEnvironment: Hashable, Sendable {
    let contentSizeCategory: String
    let userInterfaceStyle: Int
}
#endif
