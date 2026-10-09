#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Parsed documents and the per-message "Show Markdown Source" state.
/// Parse results are cached by text. A text that extends a cached text (a stream)
/// re-parses only from its previous last top-level block: every block before it is
/// final (CommonMark decides a block from the lines before it, except the open
/// one at the end), so finished blocks keep their identity and their cached layout.
final class MarkdownStore: @unchecked Sendable {
    static let shared = MarkdownStore()
    private let lock = NSLock()
    private var docs: [String: MDDocument] = [:]
    /// Recent texts in insertion order (stream prefix lookup).
    private var recent: [String] = []
    private(set) var fullParses = 0, tailParses = 0
    /// Messages shown as source (main thread writes; the measure key reads).
    private var source = Set<ID>()

    func showsSource(_ id: ID) -> Bool { lock.lock(); defer { lock.unlock() }; return source.contains(id) }
    func setShowsSource(_ id: ID, _ on: Bool) { lock.lock(); if on { source.insert(id) } else { source.remove(id) }; lock.unlock() }

    func document(_ text: String) -> MDDocument {
        lock.lock()
        if let d = docs[text] { lock.unlock(); return d }
        // The newest cached text that this text extends.
        var base: (String, MDDocument)?
        for t in recent.reversed() where t.utf8.count < text.utf8.count && text.hasPrefix(t) {
            if let d = docs[t] { base = (t, d); break }
        }
        lock.unlock()
        let doc: MDDocument
        if let (_, old) = base, let last = old.blocks.last, !last.lines.isEmpty, !Self.hasDefinitions(text) {
            let lines = MDLines.split(text).map { MDLine($0) }
            let from = last.lines.lowerBound
            var refs = MDRefs()
            var tail = MDBlockParser.parse(Array(lines[min(from, lines.count)...]), refs: &refs, known: nil, topLevel: true)
            for i in tail.indices { tail[i].lines = (tail[i].lines.lowerBound + from)..<(tail[i].lines.upperBound + from) }
            if let first = tail.first, var t0 = Optional(first) {
                t0.blankBefore = last.blankBefore
                tail[0] = t0
            }
            let blocks = Array(old.blocks.dropLast()) + tail
            doc = MDDocument(blocks: blocks, isRich: blocks.contains { $0.rich })
            lock.lock(); tailParses += 1; lock.unlock()
        } else {
            doc = Markdown.parse(text)
            lock.lock(); fullParses += 1; lock.unlock()
        }
        lock.lock()
        docs[text] = doc
        recent.append(text)
        if recent.count > 64 {
            let drop = recent.removeFirst()
            if !recent.contains(drop) { docs[drop] = nil }
        }
        lock.unlock()
        return doc
    }

    /// Reference definitions make earlier blocks depend on later text: full parse.
    static func hasDefinitions(_ text: String) -> Bool { text.contains("]:") }
}

extension Markdown {
    /// The markdown layout of a text part, or nil for the plain path: markdown off,
    /// a long text (LongText; shared/LONG-MESSAGES.md), no rich element, or the
    /// message shown as source.
    static func layout(_ text: String, message: ID?, width: CGFloat) -> MarkdownLayout? {
        guard enabled, mightContain(text), !LongText.isLong(text) else { return nil }
        if let message, MarkdownStore.shared.showsSource(message) { return nil }
        let doc = MarkdownStore.shared.document(text)
        guard doc.isRich else { return nil }
        return MarkdownLayoutEngine.layout(doc, source: text, maxWidth: Metrics(width: width).maxTextWidth)
    }

    /// The display string of a text part (what selection offsets index and Copy returns), or nil
    /// when the part takes the plain path (then the source is the display string). Independent of
    /// the width (only line breaks depend on it); thread safe; block layouts are cached.
    static func displayText(_ text: String, message: ID?) -> String? {
        layout(text, message: message, width: Fixture.windowWidth)?.plain
    }

    /// Measure-key salt: a message shown as source is a new measurement.
    static func versionSalt(_ id: ID) -> Int { MarkdownStore.shared.showsSource(id) ? 0x5EED : 0 }
}
