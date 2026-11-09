import AppKit

/// `appearance.font` live on chrome already on screen (#39272 review F1): a label takes its font
/// once, when it is made, so a change of the app font (or its palette preview) reaches only new
/// labels. On each change this walks every window's views once and gives each text control,
/// text view run and ``ChromeTextLayer`` drawn in the old app face (the default design: the
/// system font, or the last `appearance.font`) the same size and weight in the new one. Monospaced
/// faces, tabular-digit fonts, italics and other named families keep theirs. One walk per change
/// (a palette highlight move), proportional to the views on screen; views made later read
/// `Typography`.
enum AppFontRetarget {
    static func apply(from old: String?, to new: String?) {
        guard old != new else { return }
        for window in NSApp?.windows ?? [] {
            guard let root = window.contentView?.superview ?? window.contentView else { continue }
            apply(to: root, from: old, to: new)
        }
    }

    static func apply(to view: NSView, from old: String?, to new: String?) {
        if let text = view as? NSTextView {
            retarget(text, from: old, to: new)
        } else if let control = view as? NSControl, let font = control.font, let next = retargeted(font, from: old, to: new) {
            control.font = next
            control.invalidateIntrinsicContentSize()
        }
        if let layer = view.layer { apply(to: layer, from: old, to: new) }
        for subview in view.subviews { apply(to: subview, from: old, to: new) }
    }

    private static func apply(to layer: CALayer, from old: String?, to new: String?) {
        if let text = layer as? ChromeTextLayer, let next = retargeted(text.font, from: old, to: new) { text.font = next }
        for sublayer in layer.sublayers ?? [] { apply(to: sublayer, from: old, to: new) }
    }

    /// Every run of the text in the old face, and the typing font, so rich text keeps its other runs.
    private static func retarget(_ text: NSTextView, from old: String?, to new: String?) {
        if let storage = text.textStorage, storage.length > 0 {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let font = value as? NSFont, let next = retargeted(font, from: old, to: new) else { return }
                storage.addAttribute(.font, value: next, range: range)
            }
            storage.endEditing()
        }
        if let font = text.typingAttributes[.font] as? NSFont, let next = retargeted(font, from: old, to: new) {
            text.typingAttributes[.font] = next
        }
    }

    /// `font` at its size and weight in `new`'s face (nil: the system font), or nil when `font` is
    /// not in `old`'s face as `Typography`'s default design draws it.
    static func retargeted(_ font: NSFont, from old: String?, to new: String?) -> NSFont? {
        guard isAppFace(font, old) else { return nil }
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let weight = (traits?[.weight] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
        return CheckedFont.system(.default, family: new, size: font.pointSize, weight: NSFont.Weight(weight))
    }

    private static func isAppFace(_ font: NSFont, _ family: String?) -> Bool {
        let descriptor = font.fontDescriptor
        // Tabular digits (`monospacedDigit`) are the system family with a feature setting; italics are a choice.
        if descriptor.object(forKey: .featureSettings) != nil || descriptor.symbolicTraits.contains(.italic) { return false }
        return font.familyName == (family ?? systemFamily)
    }

    private static let systemFamily = NSFont.systemFont(ofSize: NSFont.systemFontSize).familyName
}
