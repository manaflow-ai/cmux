// cmux: how often the message box redrew its pictures (Draft+InlineMarks.swift). Not a vendored file.
import AppKit
import ObjectiveC

extension NSTextView {
    /// The updates this field made for pictures whose thumbnails arrived (HomeComposerPastePicturesCostTests).
    var inlineRedrawUpdates: Int { (inlineRedrawCountKey.value(on: self) as? Int) ?? 0 }

    /// Counts one update for arrived thumbnails.
    func countInlineRedraw() {
        inlineRedrawCountKey.set(inlineRedrawUpdates + 1, on: self)
    }
}

// The associated-object key (its address only).
private let inlineRedrawCountKey = AssociationKey()
