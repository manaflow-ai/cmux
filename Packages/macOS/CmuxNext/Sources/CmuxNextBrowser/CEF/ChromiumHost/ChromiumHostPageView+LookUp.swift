#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its page view.
public import AppKit

/// The word a page has at a point, for Look Up: what Chrome's `ShowDictionaryOverlay` carries (the
/// word with its font, and its baseline point) in page points from the top left.
nonisolated struct ChromiumHostLookUpWord: Equatable, Sendable, Decodable {
    var word: String
    var x: Double
    var baseline: Double
    var size: Double
    var family: String

    /// The longest word the page hands back: Look Up takes a word, not a paragraph.
    static let maxLength = 64

    /// Decodes the page's answer (``script(at:scale:)``); nil for no word or a malformed answer.
    init?(result: CEFEvaluationResult) {
        guard result.status == 1, !result.text.isEmpty, result.text != "null",
              let word = try? JSONDecoder().decode(Self.self, from: Data(result.text.utf8)),
              !word.word.isEmpty, word.word.count <= Self.maxLength, word.size.isFinite, word.size > 0 else { return nil }
        self = word
    }

    init(word: String, x: Double, baseline: Double, size: Double, family: String) {
        (self.word, self.x, self.baseline, self.size, self.family) = (word, x, baseline, size, family)
    }

    /// The renderer's word at `point` (top-left page points): the text position under the point
    /// (`caretRangeFromPoint`, the hit test Blink's word at point starts from), widened to the word
    /// around it, only when the point is inside that word's box; its box's left and bottom and its
    /// font, all back in page points. `scale` is the window's backing scale: the page's zoom is
    /// `devicePixelRatio / scale`.
    static func script(at point: CGPoint, scale: CGFloat) -> String {
        let x = point.x.isFinite ? Double(point.x) : 0
        let y = point.y.isFinite ? Double(point.y) : 0
        let backing = scale.isFinite && scale > 0 ? Double(scale) : 1
        return """
        (() => {
          const z = (devicePixelRatio / \(backing)) || 1, x = \(x) / z, y = \(y) / z;
          const at = document.caretRangeFromPoint(x, y);
          if (!at || at.startContainer.nodeType !== Node.TEXT_NODE) return null;
          const node = at.startContainer, text = node.data, part = /[\\p{L}\\p{N}\\p{M}_'\\u2019-]/u;
          let start = at.startOffset, end = start;
          while (start > 0 && part.test(text[start - 1])) start--;
          while (end < text.length && part.test(text[end])) end++;
          if (start === end || end - start > \(maxLength)) return null;
          const range = document.createRange();
          range.setStart(node, start);
          range.setEnd(node, end);
          const box = range.getBoundingClientRect();
          if (x < box.left || x > box.right || y < box.top || y > box.bottom) return null;
          const style = getComputedStyle(node.parentElement);
          return {word: text.slice(start, end), x: box.left * z, baseline: box.bottom * z,
                  size: parseFloat(style.fontSize) * z, family: style.fontFamily};
        })()
        """
    }

    /// The word with the page's font, as `showDefinition(for:at:)` draws it over the page: the first
    /// installed family of the CSS list, else the system font, at the page's size.
    var attributedString: NSAttributedString {
        let families = family.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
        let size = CGFloat(size)
        let font = families.lazy.compactMap { NSFont(name: $0, size: size) }.first ?? NSFont.systemFont(ofSize: size)
        return NSAttributedString(string: word, attributes: [.font: font])
    }
}

/// Look Up of the word under a force click or three-finger tap (task 054 of
/// plans/cmux-next/chrome-parity/p01-process.md), as Chrome's page view does it
/// (content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm `-quickLookWithEvent:`:
/// `LookUpDictionaryOverlayAtPoint`, answered by `ShowDictionaryOverlay`). The word comes from the
/// pane (``wordLookUp``); with none, the page's pushed selection (``showDefinitionForSelection()``,
/// task 047), and without that AppKit's own Look Up runs.
extension ChromiumHostPageView {
    public override func quickLook(with event: NSEvent) {
        guard let wordLookUp else {
            if !showDefinitionForSelection() { super.quickLook(with: event) }
            return
        }
        let point = pagePoint(event)
        wordLookUp(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)), window?.backingScaleFactor ?? 1) { [weak self] word in
            guard let self, let word else { return }
            showDefinition(of: word)
        }
    }

    /// Shows the dictionary panel for `word` at its baseline (page points from the top left; this
    /// view's origin is the bottom left).
    func showDefinition(of word: ChromiumHostLookUpWord) {
        showDefinition(for: word.attributedString, at: NSPoint(x: word.x, y: Double(bounds.height) - word.baseline))
    }
}
#endif
