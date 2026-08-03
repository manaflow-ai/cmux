#if os(iOS)
/// Result of delivering one exact transcript to a terminal.
struct MobileShellVoiceDelivery: Equatable, Sendable {
    let targetTitle: String
    let queued: Bool
}
#endif
