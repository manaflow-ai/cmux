#if canImport(AppKit)
import AppKit
import Foundation

/// An `NSScrollView` whose intrinsic height tracks its text content, clamped
/// between one line and a few lines, so the SwiftUI composer grows with input
/// and then scrolls.
final class ComposerScrollView: NSScrollView {
    /// The growth cap, in text lines.
    private let maxVisibleLines: CGFloat = 6

    override var intrinsicContentSize: NSSize {
        guard let textView = documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: container)
        let usedHeight = layoutManager.usedRect(for: container).height
        let lineHeight = layoutManager.defaultLineHeight(
            for: textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        )
        let insets = textView.textContainerInset.height * 2
        let clamped = min(max(usedHeight, lineHeight), lineHeight * maxVisibleLines) + insets
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(clamped))
    }
}
#endif
