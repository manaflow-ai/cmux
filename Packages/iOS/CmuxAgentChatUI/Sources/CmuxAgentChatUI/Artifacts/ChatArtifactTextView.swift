#if canImport(UIKit)
import SwiftUI
import UIKit

/// Displays large artifact text without asking SwiftUI to lay out one monolithic `Text` view.
struct ChatArtifactTextView: UIViewRepresentable {
    let documentID: String
    let chunks: [String]

    func makeCoordinator() -> ChatArtifactTextViewCoordinator {
        ChatArtifactTextViewCoordinator()
    }

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
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let isNewDocument = context.coordinator.documentID != documentID
        if isNewDocument {
            textView.textStorage.setAttributedString(NSAttributedString())
            textView.selectedRange = NSRange(location: 0, length: 0)
            context.coordinator.documentID = documentID
            context.coordinator.appliedChunkCount = 0
        }

        guard context.coordinator.appliedChunkCount <= chunks.count else {
            context.coordinator.appliedChunkCount = 0
            textView.textStorage.setAttributedString(NSAttributedString())
        }

        let font = textView.font ?? UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .regular
        )
        let textColor = textView.textColor ?? UIColor.label
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        while context.coordinator.appliedChunkCount < chunks.count {
            let chunk = chunks[context.coordinator.appliedChunkCount]
            let contentOffset = textView.contentOffset
            let selection = textView.selectedRange
            textView.textStorage.beginEditing()
            textView.textStorage.append(NSAttributedString(string: chunk, attributes: attributes))
            textView.textStorage.endEditing()
            textView.selectedRange = selection
            textView.setContentOffset(contentOffset, animated: false)
            context.coordinator.appliedChunkCount += 1
        }

        if isNewDocument {
            textView.setContentOffset(
                CGPoint(
                    x: -textView.adjustedContentInset.left,
                    y: -textView.adjustedContentInset.top
                ),
                animated: false
            )
        }
    }
}
#endif
