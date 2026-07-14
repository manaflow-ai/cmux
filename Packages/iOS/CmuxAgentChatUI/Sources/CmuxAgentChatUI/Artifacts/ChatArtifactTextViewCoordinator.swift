#if canImport(UIKit)
import Foundation
import UIKit

/// Tracks which streamed chunks have been applied to one text-storage instance.
@MainActor
final class ChatArtifactTextViewCoordinator {
    var documentID: String?
    var appliedChunkCount = 0
    var handledTopRequestID = 0
    var handledBottomRequestID = 0
    private let syntaxHighlighter = ChatArtifactSyntaxHighlighter()
    private var highlightTask: Task<Void, Never>?
    private var highlightGeneration = 0
    private var highlightedDocumentID: String?
    private var highlightedTextLength = 0
    private var highlightedLanguage: String?
    private var highlightedTheme: ChatArtifactHighlightTheme?

    func resetHighlighting() {
        highlightTask?.cancel()
        highlightTask = nil
        highlightGeneration += 1
        highlightedDocumentID = nil
        highlightedTextLength = 0
        highlightedLanguage = nil
        highlightedTheme = nil
    }

    func updateHighlighting(
        in textView: UITextView,
        documentID: String,
        text: String,
        reachedEOF: Bool,
        decision: ChatArtifactHighlightDecision,
        theme: ChatArtifactHighlightTheme
    ) {
        guard reachedEOF,
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

        highlightTask?.cancel()
        highlightGeneration += 1
        let generation = highlightGeneration
        let highlighter = syntaxHighlighter
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
            self.highlightTask = nil
        }
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
