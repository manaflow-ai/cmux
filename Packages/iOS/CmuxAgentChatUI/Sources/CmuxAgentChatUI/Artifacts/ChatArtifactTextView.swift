#if canImport(UIKit)
import SwiftUI
import UIKit

/// Displays large artifact text without asking SwiftUI to lay out one monolithic `Text` view.
struct ChatArtifactTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        // A default UITextView uses TextKit 2 on modern iOS. Large artifacts
        // then synchronously create layout fragments during fast scrolling.
        // Opt into the TextKit 1 stack so non-contiguous glyph layout remains
        // genuinely lazy instead of entering TextKit 2 compatibility mode.
        let textView = UITextView(usingTextLayoutManager: false)
        textView.layoutManager.allowsNonContiguousLayout = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = true
        textView.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .regular
        )
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.text = text
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        guard textView.text != text else { return }
        textView.text = text
    }
}
#endif
