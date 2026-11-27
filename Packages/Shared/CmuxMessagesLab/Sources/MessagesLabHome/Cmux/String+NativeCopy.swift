import Foundation

extension String {
    /// A native copy of `text`, the composer field's `string`.
    ///
    /// The field's text is its text storage's NSString, which a Swift String reads through
    /// Objective-C one character at a time: every compare or prefix check of such a draft walked
    /// the whole draft grapheme by grapheme (`ComposeView.update` and `ComposeView.lines` on every
    /// key, 14 to 21 ms a key at a 3000 character draft on cmux21). The draft the store keeps is
    /// this copy, contiguous UTF-8, so those checks are byte compares. A lone surrogate becomes
    /// U+FFFD, as reading the bridged string gives it.
    init(nativeCopyOf text: String) {
        let ns = text as NSString
        let count = ns.length
        guard count > 0 else { self = ""; return }
        var units = [unichar](repeating: 0, count: count)
        ns.getCharacters(&units, range: NSRange(location: 0, length: count))
        self = String(decoding: units, as: UTF16.self)
    }
}
