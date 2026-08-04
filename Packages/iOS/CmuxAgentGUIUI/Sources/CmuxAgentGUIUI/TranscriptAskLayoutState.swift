#if os(iOS)
struct TranscriptAskLayoutState: Equatable, Sendable {
    let isAnswering: Bool
    let hasFailed: Bool

    static let idle = Self(isAnswering: false, hasFailed: false)
}
#endif
