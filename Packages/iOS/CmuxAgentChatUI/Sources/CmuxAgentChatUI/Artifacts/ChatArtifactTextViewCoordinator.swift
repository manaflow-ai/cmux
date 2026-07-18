#if canImport(UIKit)
import Foundation
import UIKit

/// Tracks which streamed chunks have been applied to one text-storage instance.
@MainActor
final class ChatArtifactTextViewCoordinator:
    NSObject,
    UITextViewDelegate,
    UIGestureRecognizerDelegate
{
    private enum BottomPinTrigger: Int {
        case layoutChanged
        case appendsFlushed
        case reachedEOF
    }

    var documentID: String?
    var appliedChunkCount = 0
    var handledTopRequestID = 0
    var handledBottomRequestID = 0
    var handledGoToLineRequestID = 0
    var onFontSizeChanged: ((Double) -> Void)?
    private(set) var accessibilityContent = ChatArtifactTextAccessibilityContent()
    private var appendPolicy = ChatArtifactTextAppendPolicy()
    private var pendingTextChunks: [String] = []
    private var pendingTextAttributes: [NSAttributedString.Key: Any] = [:]
    private var pendingLineNumberUpdate: (index: ChatArtifactLineIndex, isVisible: Bool)?
    private var latestPostAppendWork: (() -> Void)?
    private var topJumpConvergence: ChatArtifactTextJumpConvergence?
    private var bottomPin = ChatArtifactTextBottomPinStateMachine()
    private var endJumpConvergence: ChatArtifactTextJumpConvergence?
    private var isSettlingBoundaryJump = false
    private var pendingBottomPinTriggerMask = 0
    private weak var containerView: ChatArtifactTextContainerView?
    private let syntaxHighlighter = ChatArtifactSyntaxHighlighter()
    private var highlightTask: Task<Void, Never>?
    private var highlightGeneration = 0
    private var highlightedDocumentID: String?
    private var highlightedTextLength = 0
    private var highlightedLanguage: String?
    private var highlightedTheme: ChatArtifactHighlightTheme?
    private var pendingHighlightDocumentID: String?
    private var pendingHighlightTextLength = 0
    private var pendingHighlightLanguage: String?
    private var pendingHighlightTheme: ChatArtifactHighlightTheme?
    private var searchModel = ChatArtifactSearchModel()
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var searchedDocumentID: String?
    private var searchedTextLength = 0
    private var pendingSearchDocumentID: String?
    private var pendingSearchTextLength = 0
    private var pendingSearchQuery = ""
    private var handledPreviousSearchRequestID = 0
    private var handledNextSearchRequestID = 0
    private var appliedSearchRange: NSRange?
    private var onSearchSummaryChanged: ((ChatArtifactSearchSummary) -> Void)?
    private var publishedSearchSummary = ChatArtifactSearchSummary.empty
    private var summaryPublishGeneration = 0
    private let searchDebounce: Duration
    private var appliedFontPointSize = 0.0
    private var pinchStartFontPointSize = 0.0
    private lazy var fontPinchGestureRecognizer: UIPinchGestureRecognizer = {
        let recognizer = UIPinchGestureRecognizer(target: self, action: #selector(handleFontPinch(_:)))
        recognizer.cancelsTouchesInView = false
        return recognizer
    }()
    private lazy var bottomPinExitTapGestureRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleUserTap(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    init(searchDebounce: Duration = .milliseconds(160)) {
        self.searchDebounce = searchDebounce
        super.init()
    }

    func attach(_ containerView: ChatArtifactTextContainerView) {
        self.containerView = containerView
        containerView.textView.addGestureRecognizer(fontPinchGestureRecognizer)
        containerView.textView.addGestureRecognizer(bottomPinExitTapGestureRecognizer)
        if let textView = containerView.textView as? ChatArtifactUIKitTextView {
            textView.onLayoutDidChange = { [weak self, weak textView] in
                guard let textView else { return }
                self?.textViewLayoutDidChange(in: textView)
            }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        containerView?.gutterView.setNeedsDisplay()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        cancelBoundaryJumpOwnership()
        appendPolicy.beginTracking()
        suspendTextStorageWork()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        resumeDeferredUpdates(
            releasedChunkCount: appendPolicy.endTracking(willDecelerate: decelerate),
            in: scrollView as? UITextView
        )
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        resumeDeferredUpdates(
            releasedChunkCount: appendPolicy.endDecelerating(),
            in: scrollView as? UITextView
        )
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        resumeDeferredUpdates(
            releasedChunkCount: appendPolicy.endProgrammaticAnimation(),
            in: scrollView as? UITextView
        )
    }

    private func textViewLayoutDidChange(in textView: UITextView) {
        settleBoundaryJumpIfReady(in: textView, bottomPinTrigger: .layoutChanged)
    }

    private func cancelBottomPinOwnership() {
        endJumpConvergence = nil
        pendingBottomPinTriggerMask = 0
        bottomPin.userInteracted()
    }

    private func cancelBoundaryJumpOwnership() {
        topJumpConvergence = nil
        cancelBottomPinOwnership()
    }

    func resetStreamingText() {
        appendPolicy.reset()
        pendingTextChunks.removeAll(keepingCapacity: false)
        pendingTextAttributes.removeAll(keepingCapacity: false)
        pendingLineNumberUpdate = nil
        latestPostAppendWork = nil
        topJumpConvergence = nil
        bottomPin = ChatArtifactTextBottomPinStateMachine()
        endJumpConvergence = nil
        pendingBottomPinTriggerMask = 0
        appliedChunkCount = 0
    }

    func enqueueTextChunks(
        _ chunks: ArraySlice<String>,
        attributes: [NSAttributedString.Key: Any],
        in textView: UITextView
    ) {
        guard !chunks.isEmpty else { return }
        pendingTextChunks.append(contentsOf: chunks)
        pendingTextAttributes = attributes
        appliedChunkCount += chunks.count
        for chunk in chunks {
            appendAccessibilityContent(chunk)
        }
        let releasedChunkCount = appendPolicy.enqueue(chunkCount: chunks.count)
        if releasedChunkCount > 0 {
            flushPendingText(releasedChunkCount: releasedChunkCount, in: textView)
        }
    }

    func updateLineNumbers(index: ChatArtifactLineIndex, isVisible: Bool) {
        pendingLineNumberUpdate = (index, isVisible)
        applyPendingLineNumbersIfReady()
    }

    func schedulePostAppendWork(_ work: @escaping () -> Void) {
        latestPostAppendWork = work
        runPostAppendWorkIfReady()
    }

    func scrollToTop(in textView: UITextView, animated: Bool) {
        cancelBottomPinOwnership()
        let target = documentTopContentOffset(in: textView)
        guard animated else {
            topJumpConvergence = nil
            textView.setContentOffset(target, animated: false)
            return
        }

        topJumpConvergence = ChatArtifactTextJumpConvergence(
            initialTargetOffset: Double(target.y)
        )
        if !setContentOffset(target, animated: true, in: textView) {
            topJumpConvergence = nil
        }
    }

    func requestEndJump(
        _ target: ChatArtifactTextEndJumpTarget,
        in textView: UITextView
    ) {
        topJumpConvergence = nil
        let boundary = documentEndBoundary(in: textView)
        endJumpConvergence = ChatArtifactTextJumpConvergence(
            initialTargetOffset: boundary.contentOffsetY
        )
        let action = bottomPin.engage(target: target, boundary: boundary)
        if !applyBottomPinAction(action, in: textView) {
            settleBoundaryJumpIfReady(in: textView)
        }
    }

    func reconcileEndJump(reachedEOF: Bool, in textView: UITextView) {
        guard reachedEOF else { return }
        if endJumpConvergence != nil || appendPolicy.isDeferring {
            bottomPin.markReachedEOF()
            return
        }
        settleBoundaryJumpIfReady(in: textView, bottomPinTrigger: .reachedEOF)
    }

    func scrollToUTF16Offset(_ offset: Int, in textView: UITextView) {
        cancelBoundaryJumpOwnership()
        textView.scrollRangeToVisible(NSRange(
            location: min(max(offset, 0), textView.textStorage.length),
            length: 0
        ))
    }

    private func resumeDeferredUpdates(
        releasedChunkCount: Int,
        in textView: UITextView?
    ) {
        if releasedChunkCount > 0, let textView {
            flushPendingText(releasedChunkCount: releasedChunkCount, in: textView)
            return
        }
        applyPendingLineNumbersIfReady()
        runPostAppendWorkIfReady()
        if let textView {
            settleBoundaryJumpIfReady(in: textView, bottomPinTrigger: .layoutChanged)
        }
    }

    private func flushPendingText(releasedChunkCount: Int, in textView: UITextView) {
        guard !appendPolicy.isDeferring, !pendingTextChunks.isEmpty else { return }
        assert(releasedChunkCount == pendingTextChunks.count)

        let text = pendingTextChunks.joined()
        pendingTextChunks.removeAll(keepingCapacity: true)
        let attributes = pendingTextAttributes
        pendingTextAttributes.removeAll(keepingCapacity: true)
        let contentOffset = textView.contentOffset
        let selection = textView.selectedRange

        // TextKit can reset this optimization when its stack is rebuilt. Keep
        // it explicit at the edit boundary so appends only lay out the viewport.
        textView.layoutManager.allowsNonContiguousLayout = true
        textView.textStorage.beginEditing()
        textView.textStorage.append(NSAttributedString(string: text, attributes: attributes))
        textView.textStorage.endEditing()
        textView.selectedRange = selection
        textView.setContentOffset(contentOffset, animated: false)

        settleBoundaryJumpIfReady(in: textView, bottomPinTrigger: .appendsFlushed)
        applyPendingLineNumbersIfReady()
        runPostAppendWorkIfReady()
    }

    /// Settles the bounded initial animation, then lets the durable pin own later changes.
    private func settleBoundaryJumpIfReady(
        in textView: UITextView,
        bottomPinTrigger: BottomPinTrigger? = nil
    ) {
        if let bottomPinTrigger {
            pendingBottomPinTriggerMask |= 1 << bottomPinTrigger.rawValue
        }
        // UIKit may synchronously report animation completion while a fallback
        // range or a deferred append is being materialized. The active settle
        // owns that edge and drains every trigger recorded by re-entrant work.
        guard !isSettlingBoundaryJump else { return }
        isSettlingBoundaryJump = true
        defer { isSettlingBoundaryJump = false }

        guard !appendPolicy.isDeferring,
              pendingTextChunks.isEmpty else { return }

        let appendsFlushedMask = 1 << BottomPinTrigger.appendsFlushed.rawValue
        if bottomPin.phase == .initialAnimation,
           pendingBottomPinTriggerMask & appendsFlushedMask != 0 {
            pendingBottomPinTriggerMask &= ~appendsFlushedMask
            let boundary = documentEndBoundary(in: textView)
            endJumpConvergence = ChatArtifactTextJumpConvergence(
                initialTargetOffset: boundary.contentOffsetY
            )
            if applyBottomPinAction(
                bottomPin.appendsFlushed(at: boundary),
                in: textView
            ) {
                return
            }
        }

        while true {
            while settleBoundaryJumpOnceIfReady(in: textView) {}

            guard !appendPolicy.isDeferring,
                  pendingTextChunks.isEmpty,
                  endJumpConvergence == nil,
                  let bottomPinTrigger = takePendingBottomPinTrigger() else { return }
            let boundary = documentEndBoundary(in: textView)
            let action: ChatArtifactTextBottomPinStateMachine.Action
            switch bottomPinTrigger {
            case .layoutChanged:
                action = bottomPin.layoutChanged(to: boundary)
            case .appendsFlushed:
                action = bottomPin.appendsFlushed(at: boundary)
            case .reachedEOF:
                action = bottomPin.reachedEOF(at: boundary)
            }
            _ = applyBottomPinAction(action, in: textView)

            guard !appendPolicy.isDeferring,
                  pendingTextChunks.isEmpty else { return }
        }
    }

    private func takePendingBottomPinTrigger() -> BottomPinTrigger? {
        for trigger in [
            BottomPinTrigger.reachedEOF,
            .appendsFlushed,
            .layoutChanged,
        ] where pendingBottomPinTriggerMask & (1 << trigger.rawValue) != 0 {
            pendingBottomPinTriggerMask &= ~(1 << trigger.rawValue)
            return trigger
        }
        return nil
    }

    /// Performs one budgeted settle step and reports whether layout must be sampled again now.
    private func settleBoundaryJumpOnceIfReady(in textView: UITextView) -> Bool {
        if var convergence = topJumpConvergence {
            let target = documentTopContentOffset(in: textView)
            let decision = convergence.decision(
                observedOffset: Double(textView.contentOffset.y),
                targetOffset: Double(target.y)
            )
            topJumpConvergence = convergence
            return applyTopJumpDecision(decision, target: target, in: textView)
        }

        guard var convergence = endJumpConvergence else { return false }
        let boundary = documentEndBoundary(in: textView)
        let decision = convergence.decision(
            observedOffset: Double(textView.contentOffset.y),
            targetOffset: boundary.contentOffsetY
        )
        endJumpConvergence = convergence
        return applyEndJumpDecision(
            decision,
            boundary: boundary,
            in: textView
        )
    }

    private func applyTopJumpDecision(
        _ decision: ChatArtifactTextJumpConvergence.Decision,
        target: CGPoint,
        in textView: UITextView
    ) -> Bool {
        switch decision {
        case .finish:
            topJumpConvergence = nil
            return false
        case .retarget:
            if !setContentOffset(target, animated: true, in: textView) {
                textView.layoutIfNeeded()
                return true
            }
            return false
        case .force:
            topJumpConvergence = nil
            settleAtDocumentTop(in: textView)
            return false
        }
    }

    private func applyEndJumpDecision(
        _ decision: ChatArtifactTextJumpConvergence.Decision,
        boundary: ChatArtifactTextBottomBoundary,
        in textView: UITextView
    ) -> Bool {
        switch decision {
        case .finish:
            endJumpConvergence = nil
            _ = applyBottomPinAction(
                bottomPin.initialAnimationSettled(
                    at: boundary,
                    isBoundaryVisible: true
                ),
                in: textView
            )
            return false
        case .retarget:
            let target = CGPoint(
                x: textView.contentOffset.x,
                y: CGFloat(boundary.contentOffsetY)
            )
            if !setContentOffset(target, animated: true, in: textView) {
                textView.layoutIfNeeded()
                return true
            }
            return false
        case .force:
            endJumpConvergence = nil
            _ = applyBottomPinAction(
                bottomPin.initialAnimationSettled(
                    at: boundary,
                    isBoundaryVisible: false
                ),
                in: textView
            )
            return false
        }
    }

    /// Applies the state-machine decision; only the first End movement may animate.
    private func applyBottomPinAction(
        _ action: ChatArtifactTextBottomPinStateMachine.Action,
        in textView: UITextView
    ) -> Bool {
        switch action {
        case .none:
            return false
        case .scrollToBottom(let boundary, let animated):
            if animated {
                return setContentOffset(
                    CGPoint(
                        x: textView.contentOffset.x,
                        y: CGFloat(boundary.contentOffsetY)
                    ),
                    animated: true,
                    in: textView
                )
            }
            settleAtDocumentEnd(in: textView)
            bottomPin.didApplyPin(at: documentEndBoundary(in: textView))
            return false
        }
    }

    private func setContentOffset(
        _ target: CGPoint,
        animated: Bool,
        in textView: UITextView
    ) -> Bool {
        let requiresAnimation = animated
            && (abs(textView.contentOffset.x - target.x) > 0.5
                || abs(textView.contentOffset.y - target.y) > 0.5)
        if requiresAnimation {
            appendPolicy.beginProgrammaticAnimation()
            suspendTextStorageWork()
        }
        textView.setContentOffset(target, animated: requiresAnimation)
        return requiresAnimation
    }

    private func documentTopContentOffset(in textView: UITextView) -> CGPoint {
        if textView.textStorage.length > 0 {
            textView.layoutManager.allowsNonContiguousLayout = true
            textView.layoutManager.ensureLayout(
                forCharacterRange: NSRange(location: 0, length: 1)
            )
        }
        return CGPoint(
            x: -textView.adjustedContentInset.left,
            y: -textView.adjustedContentInset.top
        )
    }

    /// Lays out only the final TextKit 1 character range and returns its true bottom offset.
    private func documentEndContentOffset(in textView: UITextView) -> CGPoint {
        let minimumY = -textView.adjustedContentInset.top
        var documentBottom = textView.textContainerInset.top
            + textView.textContainerInset.bottom
        if textView.textStorage.length > 0 {
            let finalCharacterRange = NSRange(
                location: textView.textStorage.length - 1,
                length: 1
            )
            textView.layoutManager.allowsNonContiguousLayout = true
            textView.layoutManager.ensureLayout(forCharacterRange: finalCharacterRange)
            let finalGlyphRange = textView.layoutManager.glyphRange(
                forCharacterRange: finalCharacterRange,
                actualCharacterRange: nil
            )
            let finalGlyphRect = textView.layoutManager.boundingRect(
                forGlyphRange: finalGlyphRange,
                in: textView.textContainer
            )
            documentBottom += max(
                finalGlyphRect.maxY,
                textView.layoutManager.extraLineFragmentRect.maxY
            )
        }
        return CGPoint(
            x: textView.contentOffset.x,
            y: max(
                minimumY,
                documentBottom
                    - textView.bounds.height
                    + textView.adjustedContentInset.bottom
            )
        )
    }

    private func documentEndBoundary(
        in textView: UITextView
    ) -> ChatArtifactTextBottomBoundary {
        let contentOffset = documentEndContentOffset(in: textView)
        return ChatArtifactTextBottomBoundary(
            storageEnd: textView.textStorage.length,
            contentOffsetY: Double(contentOffset.y)
        )
    }

    /// Settles at the first character without materializing the intervening document.
    private func settleAtDocumentTop(in textView: UITextView) {
        if textView.textStorage.length > 0 {
            let range = NSRange(location: 0, length: 1)
            textView.layoutManager.allowsNonContiguousLayout = true
            textView.layoutManager.ensureLayout(forCharacterRange: range)
            textView.scrollRangeToVisible(range)
        }
        textView.layoutIfNeeded()
        textView.setContentOffset(documentTopContentOffset(in: textView), animated: false)
    }

    /// Settles at the final character without materializing the intervening document.
    private func settleAtDocumentEnd(in textView: UITextView) {
        if textView.textStorage.length > 0 {
            let range = NSRange(location: textView.textStorage.length - 1, length: 1)
            textView.layoutManager.allowsNonContiguousLayout = true
            textView.layoutManager.ensureLayout(forCharacterRange: range)
            textView.scrollRangeToVisible(range)
        }
        textView.layoutIfNeeded()
        textView.setContentOffset(documentEndContentOffset(in: textView), animated: false)
    }

    private func applyPendingLineNumbersIfReady() {
        guard !appendPolicy.isDeferring,
              pendingTextChunks.isEmpty,
              let update = pendingLineNumberUpdate else { return }
        pendingLineNumberUpdate = nil
        containerView?.updateLineNumbers(index: update.index, isVisible: update.isVisible)
    }

    private func runPostAppendWorkIfReady() {
        guard !appendPolicy.isDeferring,
              pendingTextChunks.isEmpty else { return }
        latestPostAppendWork?()
    }

    private func suspendTextStorageWork() {
        highlightTask?.cancel()
        highlightTask = nil
        highlightGeneration += 1
        pendingHighlightDocumentID = nil
        pendingHighlightTextLength = 0
        pendingHighlightLanguage = nil
        pendingHighlightTheme = nil

        searchTask?.cancel()
        searchTask = nil
        searchGeneration += 1
        pendingSearchDocumentID = nil
        pendingSearchTextLength = 0
        pendingSearchQuery = ""
    }

    func updateFontSize(in textView: UITextView, pointSize: Double) {
        let clamped = min(
            max(pointSize, ChatArtifactTextPreferences.minimumFontSize),
            ChatArtifactTextPreferences.maximumFontSize
        )
        guard abs(appliedFontPointSize - clamped) > 0.001 else { return }
        applyFontSize(clamped, to: textView)
    }

    @objc
    private func handleFontPinch(_ recognizer: UIPinchGestureRecognizer) {
        guard let textView = containerView?.textView else { return }
        switch recognizer.state {
        case .began:
            cancelBoundaryJumpOwnership()
            pinchStartFontPointSize = appliedFontPointSize > 0
                ? appliedFontPointSize
                : Double(textView.font?.pointSize ?? 15)
        case .changed, .ended:
            let scaled = pinchStartFontPointSize * Double(recognizer.scale)
            let quantized = (scaled * 2).rounded() / 2
            let clamped = min(
                max(quantized, ChatArtifactTextPreferences.minimumFontSize),
                ChatArtifactTextPreferences.maximumFontSize
            )
            if abs(clamped - appliedFontPointSize) > 0.001 {
                applyFontSize(clamped, to: textView)
            }
            if recognizer.state == .ended {
                onFontSizeChanged?(clamped)
            }
        case .cancelled, .failed:
            applyFontSize(pinchStartFontPointSize, to: textView)
        default:
            break
        }
    }

    @objc
    private func handleUserTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        cancelBoundaryJumpOwnership()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === bottomPinExitTapGestureRecognizer
            || otherGestureRecognizer === bottomPinExitTapGestureRecognizer
    }

    private func applyFontSize(_ pointSize: Double, to textView: UITextView) {
        let font = UIFont.monospacedSystemFont(
            ofSize: CGFloat(pointSize),
            weight: .regular
        )
        let contentOffset = textView.contentOffset
        let selection = textView.selectedRange
        textView.font = font
        if textView.textStorage.length > 0 {
            textView.textStorage.addAttribute(
                .font,
                value: font,
                range: NSRange(location: 0, length: textView.textStorage.length)
            )
        }
        textView.selectedRange = selection
        textView.setContentOffset(contentOffset, animated: false)
        appliedFontPointSize = pointSize
        if let containerView {
            containerView.updateLineNumbers(
                index: containerView.gutterView.lineIndex,
                isVisible: !containerView.gutterView.isHidden
            )
        }
    }

    func resetHighlighting() {
        highlightTask?.cancel()
        highlightTask = nil
        highlightGeneration += 1
        highlightedDocumentID = nil
        highlightedTextLength = 0
        highlightedLanguage = nil
        highlightedTheme = nil
        pendingHighlightDocumentID = nil
        pendingHighlightTextLength = 0
        pendingHighlightLanguage = nil
        pendingHighlightTheme = nil
    }

    func resetSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration += 1
        searchModel = ChatArtifactSearchModel()
        searchedDocumentID = nil
        searchedTextLength = 0
        pendingSearchDocumentID = nil
        pendingSearchTextLength = 0
        pendingSearchQuery = ""
        handledPreviousSearchRequestID = 0
        handledNextSearchRequestID = 0
        appliedSearchRange = nil
        publishSearchSummary(.empty)
    }

    func resetAccessibilityContent() {
        accessibilityContent = ChatArtifactTextAccessibilityContent()
    }

    func appendAccessibilityContent(_ text: String) {
        accessibilityContent.append(text)
    }

    func updateHighlighting(
        in textView: UITextView,
        documentID: String,
        text: String?,
        reachedEOF: Bool,
        decision: ChatArtifactHighlightDecision,
        theme: ChatArtifactHighlightTheme
    ) {
        guard let text,
              reachedEOF,
              case .highlight(let language) = decision,
              !text.isEmpty else {
            highlightTask?.cancel()
            highlightTask = nil
            return
        }
        guard highlightedDocumentID != documentID
                || highlightedTextLength != text.utf16.count
                || highlightedLanguage != language
                || highlightedTheme != theme else {
            return
        }
        guard pendingHighlightDocumentID != documentID
                || pendingHighlightTextLength != text.utf16.count
                || pendingHighlightLanguage != language
                || pendingHighlightTheme != theme else {
            return
        }

        highlightTask?.cancel()
        highlightGeneration += 1
        let generation = highlightGeneration
        let highlighter = syntaxHighlighter
        pendingHighlightDocumentID = documentID
        pendingHighlightTextLength = text.utf16.count
        pendingHighlightLanguage = language
        pendingHighlightTheme = theme
        highlightTask = Task { @MainActor [weak self, weak textView] in
            let result = await highlighter.highlight(
                text: text,
                language: language,
                theme: theme
            )
            guard let self,
                  !Task.isCancelled,
                  generation == self.highlightGeneration,
                  let textView,
                  let result,
                  result.value.string == text,
                  textView.textStorage.string == text else {
                return
            }

            self.apply(result.value, to: textView)
            self.highlightedDocumentID = documentID
            self.highlightedTextLength = text.utf16.count
            self.highlightedLanguage = language
            self.highlightedTheme = theme
            self.pendingHighlightDocumentID = nil
            self.pendingHighlightTextLength = 0
            self.pendingHighlightLanguage = nil
            self.pendingHighlightTheme = nil
            self.highlightTask = nil
        }
    }

    func updateSearch(
        in textView: UITextView,
        documentID: String,
        text: String?,
        textLength: Int,
        query: String,
        reachedEOF: Bool,
        previousRequestID: Int,
        nextRequestID: Int,
        onSummaryChanged: @escaping (ChatArtifactSearchSummary) -> Void
    ) {
        self.onSearchSummaryChanged = onSummaryChanged
        guard !query.isEmpty else {
            searchTask?.cancel()
            searchTask = nil
            searchGeneration += 1
            clearSearchHighlight(in: textView)
            searchModel = ChatArtifactSearchModel()
            searchedDocumentID = documentID
            searchedTextLength = textLength
            pendingSearchDocumentID = nil
            pendingSearchTextLength = 0
            pendingSearchQuery = ""
            handledPreviousSearchRequestID = previousRequestID
            handledNextSearchRequestID = nextRequestID
            publishSearchSummary(.empty)
            return
        }

        guard let text else { return }
        let textLength = text.utf16.count
        let hasCurrentResults = searchedDocumentID == documentID
            && searchedTextLength == textLength
            && searchModel.query == query
        let hasPendingResults = pendingSearchDocumentID == documentID
            && pendingSearchTextLength == textLength
            && pendingSearchQuery == query
        if !hasCurrentResults, !hasPendingResults {
            scheduleSearch(
                in: textView,
                documentID: documentID,
                text: text,
                query: query,
                reachedEOF: reachedEOF,
                previousRequestID: previousRequestID,
                nextRequestID: nextRequestID
            )
            return
        }
        guard hasCurrentResults else { return }
        applySearchNavigation(
            in: textView,
            previousRequestID: previousRequestID,
            nextRequestID: nextRequestID
        )
    }

    private func scheduleSearch(
        in textView: UITextView,
        documentID: String,
        text: String,
        query: String,
        reachedEOF: Bool,
        previousRequestID: Int,
        nextRequestID: Int
    ) {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let previousModel = searchModel
        let debounce = searchDebounce
        let shouldDebounce = !reachedEOF
        pendingSearchDocumentID = documentID
        pendingSearchTextLength = text.utf16.count
        pendingSearchQuery = query
        if previousModel.query != query {
            clearSearchHighlight(in: textView)
            publishSearchSummary(.empty)
        }

        searchTask = Task { @MainActor [weak self, weak textView] in
            if shouldDebounce {
                do {
                    // A bounded, cancellable debounce coalesces streamed append bursts.
                    try await Task.sleep(for: debounce)
                } catch {
                    return
                }
            }
            let nextModel = await Task.detached(priority: .userInitiated) {
                var model = previousModel
                model.update(query: query, in: text)
                return model
            }.value
            guard let self,
                  !Task.isCancelled,
                  generation == self.searchGeneration,
                  let textView,
                  textView.textStorage.string == text else {
                return
            }

            let shouldScroll = previousModel.query != query
            self.searchModel = nextModel
            self.searchedDocumentID = documentID
            self.searchedTextLength = text.utf16.count
            self.pendingSearchDocumentID = nil
            self.pendingSearchTextLength = 0
            self.pendingSearchQuery = ""
            self.handledPreviousSearchRequestID = previousRequestID
            self.handledNextSearchRequestID = nextRequestID
            self.applyCurrentSearchHighlight(in: textView, scrollToMatch: shouldScroll)
            self.publishSearchSummary(nextModel.summary)
            self.searchTask = nil
        }
    }

    private func applySearchNavigation(
        in textView: UITextView,
        previousRequestID: Int,
        nextRequestID: Int
    ) {
        var didNavigate = false
        if handledPreviousSearchRequestID != previousRequestID {
            handledPreviousSearchRequestID = previousRequestID
            searchModel.selectPrevious()
            didNavigate = true
        }
        if handledNextSearchRequestID != nextRequestID {
            handledNextSearchRequestID = nextRequestID
            searchModel.selectNext()
            didNavigate = true
        }
        guard didNavigate else { return }
        applyCurrentSearchHighlight(in: textView, scrollToMatch: true)
        publishSearchSummary(searchModel.summary)
    }

    private func apply(_ highlighted: NSAttributedString, to textView: UITextView) {
        let contentOffset = textView.contentOffset
        let selection = textView.selectedRange
        let pointSize = textView.font?.pointSize
            ?? UIFont.preferredFont(forTextStyle: .body).pointSize
        let fullRange = NSRange(location: 0, length: highlighted.length)

        textView.textStorage.beginEditing()
        highlighted.enumerateAttributes(in: fullRange) { attributes, range, _ in
            textView.textStorage.setAttributes(
                normalized(attributes, pointSize: pointSize),
                range: range
            )
        }
        textView.textStorage.endEditing()
        textView.selectedRange = selection
        textView.setContentOffset(contentOffset, animated: false)
        applyCurrentSearchHighlight(in: textView, scrollToMatch: false)
        containerView?.gutterView.setNeedsDisplay()
    }

    private func applyCurrentSearchHighlight(
        in textView: UITextView,
        scrollToMatch: Bool
    ) {
        clearSearchHighlight(in: textView)
        guard let currentRange = searchModel.currentRange,
              NSMaxRange(currentRange) <= textView.textStorage.length else {
            return
        }
        textView.textStorage.addAttribute(
            .backgroundColor,
            value: UIColor.systemYellow.withAlphaComponent(0.38),
            range: currentRange
        )
        appliedSearchRange = currentRange
        if scrollToMatch {
            cancelBoundaryJumpOwnership()
            textView.scrollRangeToVisible(currentRange)
        }
    }

    private func clearSearchHighlight(in textView: UITextView) {
        guard let appliedSearchRange,
              NSMaxRange(appliedSearchRange) <= textView.textStorage.length else {
            self.appliedSearchRange = nil
            return
        }
        textView.textStorage.removeAttribute(.backgroundColor, range: appliedSearchRange)
        self.appliedSearchRange = nil
    }

    private func publishSearchSummary(_ summary: ChatArtifactSearchSummary) {
        guard publishedSearchSummary != summary else { return }
        publishedSearchSummary = summary
        summaryPublishGeneration += 1
        let generation = summaryPublishGeneration
        let handler = onSearchSummaryChanged
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  generation == self.summaryPublishGeneration else { return }
            handler?(summary)
        }
    }

    private func normalized(
        _ attributes: [NSAttributedString.Key: Any],
        pointSize: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        var normalized = attributes
        normalized.removeValue(forKey: .backgroundColor)
        guard let highlightedFont = attributes[.font] as? UIFont else {
            normalized[.font] = UIFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
            return normalized
        }

        let traits = highlightedFont.fontDescriptor.symbolicTraits
        let weight: UIFont.Weight = traits.contains(.traitBold) ? .bold : .regular
        let baseFont = UIFont.monospacedSystemFont(ofSize: pointSize, weight: weight)
        if traits.contains(.traitItalic),
           let descriptor = baseFont.fontDescriptor.withSymbolicTraits(
               baseFont.fontDescriptor.symbolicTraits.union(.traitItalic)
           ) {
            normalized[.font] = UIFont(descriptor: descriptor, size: pointSize)
        } else {
            normalized[.font] = baseFont
        }
        return normalized
    }
}
#endif
