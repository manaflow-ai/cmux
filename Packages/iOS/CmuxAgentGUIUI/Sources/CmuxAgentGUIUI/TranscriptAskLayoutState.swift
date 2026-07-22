#if os(iOS)
struct TranscriptAskLayoutState: Equatable {
    let isAnswering: Bool
    let hasFailed: Bool

    static let idle = Self(isAnswering: false, hasFailed: false)
}
#endif
