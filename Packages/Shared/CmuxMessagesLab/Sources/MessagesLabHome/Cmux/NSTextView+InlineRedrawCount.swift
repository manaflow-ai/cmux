// cmux: how often the message box redrew its pictures (Draft+InlineMarks.swift). Not a vendored file.
import AppKit
import ObjectiveC

extension NSTextView {
    /// The updates this field made for pictures whose thumbnails arrived (HomeComposerPastePicturesCostTests).
    var inlineRedrawUpdates: Int { (objc_getAssociatedObject(self, inlineRedrawCountKey.pointer) as? Int) ?? 0 }

    /// Counts one update for arrived thumbnails.
    func countInlineRedraw() {
        objc_setAssociatedObject(self, inlineRedrawCountKey.pointer, inlineRedrawUpdates + 1, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

// The associated-object key (its address only).
private let inlineRedrawCountKey = AssociationKey()
