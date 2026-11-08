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
        // The container constructs an explicit TextKit 1 storage/layout stack
        // so non-contiguous layout remains genuinely viewport-lazy.
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
            context.coordinator.resetStreamingText()
            context.coordinator.resetHighlighting()
            context.coordinator.resetSearch()
            context.coordinator.resetAccessibilityContent()
            textView.textStorage.setAttributedString(NSAttributedString())
            textView.selectedRange = NSRange(location: 0, length: 0)
            context.coordinator.documentID = documentID
            context.coordinator.handledTopRequestID = topRequestID
            context.coordinator.handledBottomRequestID = 0
            context.coordinator.handledGoToLineRequestID = goToLineRequestID
        }

        if context.coordinator.appliedChunkCount > chunks.count {
            context.coordinator.resetStreamingText()
            context.coordinator.resetHighlighting()
            context.coordinator.resetSearch()
            context.coordinator.resetAccessibilityContent()
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
        if context.coordinator.appliedChunkCount < chunks.count {
            context.coordinator.enqueueTextChunks(
                chunks[context.coordinator.appliedChunkCount...],
                attributes: attributes,
                in: textView
            )
        }

        let coordinator = context.coordinator
        coordinator.schedulePostAppendWork { [weak coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            let updatePlan = ChatArtifactTextUpdatePlan(
                reachedEOF: reachedEOF,
                highlightDecision: highlightDecision,
                searchQuery: searchQuery
            )
            let fullText = updatePlan.requiresFullTextSnapshot
                ? textView.textStorage.string
                : nil
            coordinator.updateHighlighting(
                in: textView,
                documentID: documentID,
                text: fullText,
                reachedEOF: reachedEOF,
                decision: highlightDecision,
                theme: highlightTheme
            )
            coordinator.updateSearch(
                in: textView,
                documentID: documentID,
                text: fullText,
                textLength: textView.textStorage.length,
                query: searchQuery,
                reachedEOF: reachedEOF,
                previousRequestID: previousSearchRequestID,
                nextRequestID: nextSearchRequestID,
                onSummaryChanged: onSearchSummaryChanged
            )
        }
        coordinator.updateLineNumbers(index: lineIndex, isVisible: showsLineNumbers)
        containerView.updateAccessibility(
            documentID: documentID,
            content: context.coordinator.accessibilityContent
        )

        if isNewDocument {
            coordinator.scrollToTop(in: textView, animated: false)
        } else if coordinator.handledTopRequestID != topRequestID {
            coordinator.handledTopRequestID = topRequestID
            coordinator.scrollToTop(in: textView, animated: true)
        }
        if coordinator.handledBottomRequestID != bottomRequestID {
            coordinator.handledBottomRequestID = bottomRequestID
            coordinator.requestEndJump(
                ChatArtifactTextEndJumpTarget(reachedEOF: reachedEOF),
                in: textView
            )
        }
        if coordinator.handledGoToLineRequestID != goToLineRequestID {
            coordinator.handledGoToLineRequestID = goToLineRequestID
            coordinator.scrollToUTF16Offset(goToLineUTF16Offset, in: textView)
        }
        coordinator.reconcileEndJump(reachedEOF: reachedEOF, in: textView)
    }
}
#endif
