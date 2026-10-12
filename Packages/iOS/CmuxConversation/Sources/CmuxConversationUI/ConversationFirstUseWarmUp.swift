#if canImport(UIKit)
import UIKit

/// Work that is slow only the first time a process does it, done once,
/// away from the main thread, when the first conversation opens: otherwise
/// the first row needing it pays in the frame it scrolls in.
@MainActor
enum ConversationFirstUseWarmUp {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        Task.detached(priority: .utility) {
            // A UIKit-scoped AttributedString's first conversion (the Replay
            // button's title): ~11 ms on iOS 26.5, once per process.
            var title = AttributeContainer()
            title.font = UIFont.systemFont(ofSize: 12)
            _ = try? NSAttributedString(AttributedString("Replay", attributes: title), including: \.uiKit)
            // Core Image's first render, and each tapback's recolored art
            // for my own badge (~20 ms the first time, per kind).
            TapbackGlyph.warmSelectedImages()
        }
    }
}
#endif
