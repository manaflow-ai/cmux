import AppKit

/// `appearance.font` live on chrome already on screen (#39272 review F1): a label takes its font
/// once, when it is made, so a change of the app font (or its palette preview) reaches only new
/// labels. On each change this walks every window's views once and gives each text control,
/// ``ChromeLabel`` (and its runs), button title run, text view run and ``ChromeTextLayer`` drawn
/// in the old app face (the default design: the system font, or the last `appearance.font`) the
/// same size and weight in the new one. Monospaced
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
        } else if let label = view as? ChromeLabel {
            // The chrome label (tabs, sidebar rows, pane chrome) keeps its font and runs itself.
            if let font = label.font, let next = retargeted(font, from: old, to: new, holder: label) { label.font = next }
            if let runs = label.ownRuns, let next = retargeted(runs, from: old, to: new, holder: label) { label.attributedStringValue = next }
        } else if let control = view as? NSControl {
            if let font = control.font, let next = retargeted(font, from: old, to: new, holder: control) {
                control.font = next
                control.invalidateIntrinsicContentSize()
            }
            // A button's attributed title carries its own font, which `font` does not reach.
            if let button = control as? NSButton, button.attributedTitle.length > 0,
               let next = retargeted(button.attributedTitle, from: old, to: new, holder: button) {
                button.attributedTitle = next
            }
        }
        if let layer = view.layer { apply(to: layer, from: old, to: new) }
        for subview in view.subviews { apply(to: subview, from: old, to: new) }
    }

    private static func apply(to layer: CALayer, from old: String?, to new: String?) {
        if let text = layer as? ChromeTextLayer, let next = retargeted(text.font, from: old, to: new, holder: text) { text.font = next }
        for sublayer in layer.sublayers ?? [] { apply(to: sublayer, from: old, to: new) }
    }

    /// Every run of the text in the old face, and the typing font, so rich text keeps its other runs.
    private static func retarget(_ text: NSTextView, from old: String?, to new: String?) {
        if let storage = text.textStorage, storage.length > 0 {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let font = value as? NSFont,
                      let next = retargeted(font, from: old, to: new, holder: storage, slot: range.location) else { return }
                storage.addAttribute(.font, value: next, range: range)
            }
            storage.endEditing()
        }
        if let font = text.typingAttributes[.font] as? NSFont, let next = retargeted(font, from: old, to: new, holder: text) {
            text.typingAttributes[.font] = next
        }
    }

    /// `text` with each run in the old face moved to the new one; nil when no run is in the old face.
    static func retargeted(_ text: NSAttributedString, from old: String?, to new: String?,
                           holder: AnyObject? = nil) -> NSAttributedString? {
        let moved = NSMutableAttributedString(attributedString: text)
        var changed = false
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let font = value as? NSFont,
                  let next = retargeted(font, from: old, to: new, holder: holder, slot: range.location) else { return }
            moved.addAttribute(.font, value: next, range: range)
            changed = true
        }
        return changed ? moved : nil
    }

    /// `font` at its size and weight in `new`'s face (nil: the system font), or nil when `font` is
    /// not in `old`'s face as `Typography`'s default design draws it.
    /// `holder` (the label, control, layer or text storage the font sits on) and `slot` (a run's
    /// location; `-1` for the holder's own font) keep the weight first asked for: a face with few
    /// weights snaps (system semibold draws Georgia Bold), so reading the snapped weight back would
    /// leave semibold chrome bold after a preview and Escape.
    static func retargeted(_ font: NSFont, from old: String?, to new: String?,
                           holder: AnyObject? = nil, slot: Int = -1) -> NSFont? {
        guard isAppFace(font, old) else { return nil }
        let weight = holder.flatMap { asked(on: $0, slot: slot, for: font) } ?? traitWeight(font)
        let next = CheckedFont.system(.default, family: new, size: font.pointSize, weight: NSFont.Weight(weight))
        if let holder { remember(weight, drawn: next, on: holder, slot: slot) }
        return next
    }

    private static func traitWeight(_ font: NSFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
    }

    /// Per holder, per slot: the font this walk drew and the weight it was asked for. Weak keys, so a
    /// view that goes away takes its entry; a font the app set since (not the one drawn here) reads
    /// its own weight again.
    private final class Asked { var slots: [Int: (drawn: NSFont, weight: CGFloat)] = [:] }
    private static let asked = NSMapTable<AnyObject, Asked>.weakToStrongObjects()

    private static func asked(on holder: AnyObject, slot: Int, for font: NSFont) -> CGFloat? {
        guard let entry = asked.object(forKey: holder)?.slots[slot], entry.drawn == font else { return nil }
        return entry.weight
    }

    private static func remember(_ weight: CGFloat, drawn: NSFont, on holder: AnyObject, slot: Int) {
        let entry = asked.object(forKey: holder) ?? Asked()
        entry.slots[slot] = (drawn, weight)
        asked.setObject(entry, forKey: holder)
    }

    private static func isAppFace(_ font: NSFont, _ family: String?) -> Bool {
        let descriptor = font.fontDescriptor
        // Tabular digits (`monospacedDigit`) are the system family with a feature setting; italics are a choice.
        if descriptor.object(forKey: .featureSettings) != nil || descriptor.symbolicTraits.contains(.italic) { return false }
        // Monospaced text (code, terminal-like chrome) chose its face; no app font choice is monospaced.
        if descriptor.symbolicTraits.contains(.monoSpace) { return false }
        return font.familyName == (family ?? systemFamily)
    }

    private static let systemFamily = NSFont.systemFont(ofSize: NSFont.systemFontSize).familyName
}
