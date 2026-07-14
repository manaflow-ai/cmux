#if canImport(UIKit)
import SwiftUI
import UIKit

/// Displays large artifact text without asking SwiftUI to lay out one monolithic `Text` view.
struct ChatArtifactTextView: UIViewRepresentable {
    let documentID: String
    let chunks: [String]
    let reachedEOF: Bool
    let highlightDecision: ChatArtifactHighlightDecision
    let highlightTheme: ChatArtifactHighlightTheme
    let searchQuery: String
    let previousSearchRequestID: Int
    let nextSearchRequestID: Int
    let onSearchSummaryChanged: (ChatArtifactSearchSummary) -> Void
    let lineIndex: ChatArtifactLineIndex
    let showsLineNumbers: Bool
    let goToLineUTF16Offset: Int
    let goToLineRequestID: Int
    let wrapsLines: Bool
    let fontPointSize: Double
    let onFontSizeChanged: (Double) -> Void
    let topRequestID: Int
    let bottomRequestID: Int

    func makeCoordinator() -> ChatArtifactTextViewCoordinator {
        ChatArtifactTextViewCoordinator()
    }

    func makeUIView(context: Context) -> ChatArtifactTextContainerView {
        // The container constructs `UITextView(usingTextLayoutManager: false)`
        // so non-contiguous TextKit 1 layout remains genuinely viewport-lazy.
        let containerView = ChatArtifactTextContainerView()
        containerView.textView.delegate = context.coordinator
        context.coordinator.attach(containerView)
        context.coordinator.onFontSizeChanged = onFontSizeChanged
        return containerView
    }

    func updateUIView(_ containerView: ChatArtifactTextContainerView, context: Context) {
        let textView = containerView.textView
        context.coordinator.onFontSizeChanged = onFontSizeChanged
        let isNewDocument = context.coordinator.documentID != documentID
        if isNewDocument {
            context.coordinator.resetHighlighting()
            context.coordinator.resetSearch()
            textView.textStorage.setAttributedString(NSAttributedString())
            textView.selectedRange = NSRange(location: 0, length: 0)
            context.coordinator.documentID = documentID
            context.coordinator.appliedChunkCount = 0
            context.coordinator.handledTopRequestID = topRequestID
            context.coordinator.handledBottomRequestID = bottomRequestID
            context.coordinator.handledGoToLineRequestID = goToLineRequestID
        }

        if context.coordinator.appliedChunkCount > chunks.count {
            context.coordinator.appliedChunkCount = 0
            context.coordinator.resetHighlighting()
            context.coordinator.resetSearch()
            textView.textStorage.setAttributedString(NSAttributedString())
        }

        containerView.updateWordWrap(wrapsLines)
        context.coordinator.updateFontSize(in: textView, pointSize: fontPointSize)

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

        context.coordinator.updateHighlighting(
            in: textView,
            documentID: documentID,
            text: textView.textStorage.string,
            reachedEOF: reachedEOF,
            decision: highlightDecision,
            theme: highlightTheme
        )
        context.coordinator.updateSearch(
            in: textView,
            documentID: documentID,
            text: textView.textStorage.string,
            query: searchQuery,
            reachedEOF: reachedEOF,
            previousRequestID: previousSearchRequestID,
            nextRequestID: nextSearchRequestID,
            onSummaryChanged: onSearchSummaryChanged
        )
        containerView.updateLineNumbers(index: lineIndex, isVisible: showsLineNumbers)

        if isNewDocument {
            Self.scrollToTop(textView)
        } else {
            if context.coordinator.handledTopRequestID != topRequestID {
                context.coordinator.handledTopRequestID = topRequestID
                Self.scrollToTop(textView)
            }
            if context.coordinator.handledBottomRequestID != bottomRequestID {
                context.coordinator.handledBottomRequestID = bottomRequestID
                textView.scrollRangeToVisible(
                    NSRange(location: textView.textStorage.length, length: 0)
                )
            }
            if context.coordinator.handledGoToLineRequestID != goToLineRequestID {
                context.coordinator.handledGoToLineRequestID = goToLineRequestID
                textView.scrollRangeToVisible(NSRange(
                    location: min(max(goToLineUTF16Offset, 0), textView.textStorage.length),
                    length: 0
                ))
            }
        }
    }

    private static func scrollToTop(_ textView: UITextView) {
        textView.setContentOffset(
            CGPoint(
                x: -textView.adjustedContentInset.left,
                y: -textView.adjustedContentInset.top
            ),
            animated: false
        )
    }
}
#endif
