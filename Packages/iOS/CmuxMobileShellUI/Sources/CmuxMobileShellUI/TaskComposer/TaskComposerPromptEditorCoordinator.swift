#if os(iOS)
import SwiftUI
import UIKit

/// Bridges prompt text/focus and preserves a viewport explicitly chosen by a
/// drag until the user moves the caret or resumes typing.
@MainActor
final class TaskComposerPromptEditorCoordinator: NSObject, UITextViewDelegate {
    private var text: Binding<String>
    private var isFocused: Binding<Bool>
    private var manualContentOffset: CGPoint?

    init(text: Binding<String>, isFocused: Binding<Bool>) {
        self.text = text
        self.isFocused = isFocused
        super.init()
    }

    func update(text: Binding<String>, isFocused: Binding<Bool>) {
        self.text = text
        self.isFocused = isFocused
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        if !isFocused.wrappedValue {
            isFocused.wrappedValue = true
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if isFocused.wrappedValue {
            isFocused.wrappedValue = false
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        manualContentOffset = nil
        let newValue = textView.text ?? ""
        if text.wrappedValue != newValue {
            text.wrappedValue = newValue
        }
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !textView.isTracking, !textView.isDragging, !textView.isDecelerating else { return }
        manualContentOffset = nil
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        manualContentOffset = scrollView.contentOffset
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }
        manualContentOffset = scrollView.contentOffset
    }

    func restoreManualContentOffset(in textView: UITextView) {
        guard let manualContentOffset else { return }
        let minimumY = -textView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            textView.contentSize.height
                - textView.bounds.height
                + textView.adjustedContentInset.bottom
        )
        let target = CGPoint(
            x: manualContentOffset.x,
            y: min(max(manualContentOffset.y, minimumY), maximumY)
        )
        guard abs(textView.contentOffset.y - target.y) > 0.5 else { return }
        textView.setContentOffset(target, animated: false)
    }
}
#endif
