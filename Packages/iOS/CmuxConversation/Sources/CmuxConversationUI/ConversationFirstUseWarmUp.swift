#if canImport(UIKit)
import CmuxConversationCore
import UIKit
import UniformTypeIdentifiers

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
            warmRowSymbols()
            warmFileDetails()
            // The audio clock's monospaced digits (a font with a feature
            // setting, built and shaped the first time).
            _ = ("0:00" as NSString).size(withAttributes: [.font: AudioBubbleLayout.durationFont])
        }
    }

    /// The symbol images transcript rows show, decoded from the symbol
    /// catalog the first time each is asked for (the first ~2 ms, then
    /// 0.1-0.5 ms per symbol, in the frame a row needing it scrolls in).
    /// Same names and configurations as the rows, so the rows' lookups hit.
    nonisolated private static func warmRowSymbols() {
        for uti in [UTType.pdf, .zip, .plainText, .png, .movie, .data] {
            _ = ConversationFileThumbnailer.icon(for: ConversationFileInfo(name: "warm", uti: uti.identifier, byteCount: 0))
        }
        let bold = { (size: CGFloat) in UIImage.SymbolConfiguration(pointSize: size, weight: .bold) }
        _ = UIImage(systemName: "arrow.counterclockwise", withConfiguration: bold(10))
        _ = UIImage(systemName: "play.fill", withConfiguration: bold(16))
        _ = UIImage(systemName: "pause.fill", withConfiguration: bold(16))
        _ = UIImage(systemName: "checkmark", withConfiguration: bold(12))
        _ = UIImage(systemName: "plus", withConfiguration: bold(11))
        _ = UIImage(systemName: "safari.fill")
        _ = UIImage(systemName: "chevron.right")
    }

    /// A document's "PDF Document · 15 KB": the type descriptions come from
    /// Launch Services and the size from a number formatter, ~3 ms the
    /// first time.
    nonisolated private static func warmFileDetails() {
        for name in ["warm.pdf", "warm.zip", "warm.png", "warm.txt"] {
            _ = ConversationFileBubbleLayout.detail(for: ConversationFileInfo(name: name, mimeType: nil, byteCount: 15_000))
        }
    }
}
#endif
