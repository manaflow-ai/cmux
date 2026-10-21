#if canImport(UIKit)
import UIKit

/// A swipe down on the composer puts the keyboard away, as Messages' entry
/// view does (ChatKit: a downward `UISwipeGestureRecognizer` on
/// `CKMessageEntryView` that recognizes alongside the field's own gestures;
/// `-[CKChatController messageEntryViewSwipeDownGestureRecognized:]` closes
/// a browser in the keyboard's place, else dismisses the keyboard).
/// A transcript drag still dismisses interactively; this swipe does not
/// track the finger, the keyboard animates away on its own curve.
extension ConversationViewController {
    static let composerSwipeDownName = "conversation.composerSwipeDown"

    func installComposerSwipeDown() {
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleComposerSwipeDown(_:)))
        swipe.direction = .down
        swipe.delegate = self
        swipe.name = Self.composerSwipeDownName
        composerContainer.addGestureRecognizer(swipe)
    }

    /// Not while the field scrolls its own overflowing text down.
    func composerSwipeDownShouldBegin() -> Bool {
        let text = composer.textView
        return !(text.isScrollEnabled && text.contentOffset.y > -text.adjustedContentInset.top + 0.5)
    }

    @objc private func handleComposerSwipeDown(_ swipe: UISwipeGestureRecognizer) {
        guard swipe.state == .ended else { return }
        if photoDrawer != nil {
            dismissPhotoDrawer()
        } else if composer.textView.isFirstResponder {
            composer.textView.resignFirstResponder()
        }
    }
}
#endif
