/// The user-visible operation a foreground Sparkle check is serving.
@MainActor
enum UpdateCheckIntent: String {
    case manual
    case installLatest

    /// An accepted install always wins over a coincident plain check.
    func merged(with newer: UpdateCheckIntent) -> UpdateCheckIntent {
        self == .installLatest || newer == .installLatest ? .installLatest : .manual
    }
}
