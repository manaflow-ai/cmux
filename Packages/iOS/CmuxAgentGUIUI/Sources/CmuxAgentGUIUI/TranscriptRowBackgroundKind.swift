#if os(iOS)
enum TranscriptRowBackgroundKind: Equatable, Sendable {
    case userBubble
    case pendingBubble
    case askCard
    case codeBlock
    case inlineCode
}
#endif
