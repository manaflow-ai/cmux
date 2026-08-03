#if canImport(UIKit)
import UIKit

@MainActor
struct ChatArtifactTextViewConfiguration {
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
}

/// Native TextKit artifact surface with streaming, search, highlighting, and line navigation.
@MainActor
final class ChatArtifactTextNativeView: UIView {
    private let containerView = ChatArtifactTextContainerView()
    private let coordinator = ChatArtifactTextViewCoordinator()

    init(configuration: ChatArtifactTextViewConfiguration) {
        super.init(frame: .zero)
        containerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerView)
        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        containerView.textView.delegate = coordinator
        coordinator.attach(containerView)
        update(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(configuration: ChatArtifactTextViewConfiguration) {
        let textView = containerView.textView
        coordinator.onFontSizeChanged = configuration.onFontSizeChanged
        let isNewDocument = coordinator.documentID != configuration.documentID
        if isNewDocument {
            coordinator.resetStreamingText()
            coordinator.resetHighlighting()
            coordinator.resetSearch()
            coordinator.resetAccessibilityContent()
            textView.textStorage.setAttributedString(NSAttributedString())
            textView.selectedRange = NSRange(location: 0, length: 0)
            coordinator.documentID = configuration.documentID
            coordinator.handledTopRequestID = configuration.topRequestID
            coordinator.handledBottomRequestID = 0
            coordinator.handledGoToLineRequestID = configuration.goToLineRequestID
        }

        if coordinator.appliedChunkCount > configuration.chunks.count {
            coordinator.resetStreamingText()
            coordinator.resetHighlighting()
            coordinator.resetSearch()
            coordinator.resetAccessibilityContent()
            textView.textStorage.setAttributedString(NSAttributedString())
        }

        containerView.updateWordWrap(configuration.wrapsLines)
        coordinator.updateFontSize(in: textView, pointSize: configuration.fontPointSize)

        let font = textView.font ?? UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .regular
        )
        let textColor = textView.textColor ?? UIColor.label
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        if coordinator.appliedChunkCount < configuration.chunks.count {
            coordinator.enqueueTextChunks(
                configuration.chunks[coordinator.appliedChunkCount...],
                attributes: attributes,
                in: textView
            )
        }

        coordinator.schedulePostAppendWork { [weak coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            let updatePlan = ChatArtifactTextUpdatePlan(
                reachedEOF: configuration.reachedEOF,
                highlightDecision: configuration.highlightDecision,
                searchQuery: configuration.searchQuery
            )
            let fullText = updatePlan.requiresFullTextSnapshot
                ? textView.textStorage.string
                : nil
            coordinator.updateHighlighting(
                in: textView,
                documentID: configuration.documentID,
                text: fullText,
                reachedEOF: configuration.reachedEOF,
                decision: configuration.highlightDecision,
                theme: configuration.highlightTheme
            )
            coordinator.updateSearch(
                in: textView,
                documentID: configuration.documentID,
                text: fullText,
                textLength: textView.textStorage.length,
                query: configuration.searchQuery,
                reachedEOF: configuration.reachedEOF,
                previousRequestID: configuration.previousSearchRequestID,
                nextRequestID: configuration.nextSearchRequestID,
                onSummaryChanged: configuration.onSearchSummaryChanged
            )
        }
        coordinator.updateLineNumbers(
            index: configuration.lineIndex,
            isVisible: configuration.showsLineNumbers
        )
        containerView.updateAccessibility(
            documentID: configuration.documentID,
            content: coordinator.accessibilityContent
        )

        if isNewDocument {
            coordinator.scrollToTop(in: textView, animated: false)
        } else if coordinator.handledTopRequestID != configuration.topRequestID {
            coordinator.handledTopRequestID = configuration.topRequestID
            coordinator.scrollToTop(in: textView, animated: true)
        }
        if coordinator.handledBottomRequestID != configuration.bottomRequestID {
            coordinator.handledBottomRequestID = configuration.bottomRequestID
            coordinator.requestEndJump(
                ChatArtifactTextEndJumpTarget(reachedEOF: configuration.reachedEOF),
                in: textView
            )
        }
        if coordinator.handledGoToLineRequestID != configuration.goToLineRequestID {
            coordinator.handledGoToLineRequestID = configuration.goToLineRequestID
            coordinator.scrollToUTF16Offset(configuration.goToLineUTF16Offset, in: textView)
        }
        coordinator.reconcileEndJump(reachedEOF: configuration.reachedEOF, in: textView)
    }
}
#endif
