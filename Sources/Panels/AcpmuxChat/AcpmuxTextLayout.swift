import AppKit

/// One attributed string laid out once with TextKit 1 at a fixed width.
///
/// A layout is built on any thread (TextKit 1 objects may be used off the main thread as
/// long as one thread uses a given group at a time) and handed to the main thread, which
/// is its only user after that. A transcript cell draws it by adopting its text container,
/// so showing a row never lays text out on the main thread. The configuration (zero
/// padding and insets) matches ``AcpmuxTranscriptTextView``.
final class AcpmuxTextLayout: @unchecked Sendable {
    let storage: NSTextStorage
    let layoutManager: NSLayoutManager
    let container: NSTextContainer
    /// The used size, rounded up to whole points.
    let usedSize: CGSize

    init(text: NSAttributedString, width: CGFloat) {
        storage = NSTextStorage(attributedString: text)
        layoutManager = NSLayoutManager()
        // Background layout would race the owning thread; this layout is complete up front.
        layoutManager.backgroundLayoutEnabled = false
        container = NSTextContainer(size: NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        usedSize = CGSize(width: ceil(used.width), height: ceil(max(used.height, 1)))
    }

    /// An empty layout, for rows without text.
    static func empty() -> AcpmuxTextLayout {
        AcpmuxTextLayout(text: NSAttributedString(), width: 1)
    }

    /// Draws the text into the current graphics context at `origin` (flipped coordinates).
    func draw(at origin: CGPoint) {
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }
}
