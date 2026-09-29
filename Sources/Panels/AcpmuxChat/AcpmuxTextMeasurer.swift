import AppKit

/// Measures attributed strings with the same TextKit 1 configuration the transcript
/// cells use (zero padding and insets), so cached heights match rendered heights.
@MainActor
final class AcpmuxTextMeasurer {
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))

    init() {
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    /// The used size of `text` wrapped at `width`, rounded up to whole points.
    func size(of text: NSAttributedString, width: CGFloat) -> CGSize {
        container.size = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        storage.setAttributedString(text)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return CGSize(width: ceil(used.width), height: ceil(max(used.height, 1)))
    }
}
