#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import CmuxSafeConcurrency // cmux: Mutex (p10-stability-055)

/// Parsed documents and the per-message "Show Markdown Source" state.
/// Parse results are cached by text. A text that extends a cached text (a stream)
/// re-parses only from its previous last top-level block: every block before it is
/// final (CommonMark decides a block from the lines before it, except the open
/// one at the end), so finished blocks keep their identity and their cached layout.
/// cmux: checked `Sendable` (p10-stability-055): the cache, the recent texts, the counters and the
/// source set are one lock state (they were vars under an NSLock in an unchecked class); parsing runs
/// outside the lock, as before.
final class MarkdownStore: Sendable {
    static let shared = MarkdownStore()
    private struct State: Sendable {
        var docs: [String: MDDocument] = [:]
        /// Recent texts in insertion order (stream prefix lookup).
        var recent: [String] = []
        var fullParses = 0, tailParses = 0
        /// Messages shown as source (main thread writes; the measure key reads).
        var source = Set<ID>()
    }
    // Lock carve-out: the measure threads and main look up and store parsed documents; no parse under the lock.
    private let state = Mutex(State())
    var fullParses: Int { state.withLock { $0.fullParses } }
    var tailParses: Int { state.withLock { $0.tailParses } }

    func showsSource(_ id: ID) -> Bool { state.withLock { $0.source.contains(id) } }
    func setShowsSource(_ id: ID, _ on: Bool) {
        state.withLock { s in
            if on { _ = s.source.insert(id) } else { _ = s.source.remove(id) }
        }
    }

    func document(_ text: String) -> MDDocument {
        enum Found: Sendable { case cached(MDDocument), extends(MDDocument?) }
        let found = state.withLock { s -> Found in
            if let d = s.docs[text] { return .cached(d) }
            // The newest cached text that this text extends.
            for t in s.recent.reversed() where t.utf8.count < text.utf8.count && text.hasPrefix(t) {
                if let d = s.docs[t] { return .extends(d) }
            }
            return .extends(nil)
        }
        let base: MDDocument?
        switch found {
        case let .cached(d): return d
        case let .extends(d): base = d
        }
        let doc: MDDocument
        if let old = base, let last = old.blocks.last, !last.lines.isEmpty, !Self.hasDefinitions(text) {
            let lines = MDLines.split(text).map { MDLine($0) }
            let from = last.lines.lowerBound
            var refs = MDRefs()
            var tail = MDBlockParser.parse(Array(lines.slice(from: min(from, lines.count))), refs: &refs, known: nil, topLevel: true) // clamped slice
            tail = tail.map { var b = $0; b.lines = (b.lines.lowerBound + from)..<(b.lines.upperBound + from); return b } // no index writes
            if let first = tail.first, var t0 = Optional(first) {
                t0.blankBefore = last.blankBefore
                tail[0] = t0
            }
            let blocks = Array(old.blocks.dropLast()) + tail
            doc = MDDocument(blocks: blocks, isRich: blocks.contains { $0.rich })
            state.withLock { $0.tailParses += 1 }
        } else {
            doc = Markdown.parse(text)
            state.withLock { $0.fullParses += 1 }
        }
        state.withLock { s in
            s.docs[text] = doc
            s.recent.append(text)
            if s.recent.count > 64 {
                let drop = s.recent.removeFirst()
                if !s.recent.contains(drop) { s.docs[drop] = nil }
            }
        }
        return doc
    }

    /// Reference definitions make earlier blocks depend on later text: full parse.
    static func hasDefinitions(_ text: String) -> Bool { text.contains("]:") }
}

extension Markdown {
    /// The markdown layout of a text part, or nil for the plain path: the message is not
    /// marked markdown (`format`, plain by default: opt-in), markdown off, a long text
    /// (LongText; shared/LONG-MESSAGES.md), no rich element, or the message shown as source.
    static func layout(_ text: String, message: ID?, format: MessageFormat?, width: CGFloat) -> MarkdownLayout? {
        guard format == .markdown, enabled, mightContain(text), !LongText.isLong(text) else { return nil }
        if let message, MarkdownStore.shared.showsSource(message) { return nil }
        let doc = MarkdownStore.shared.document(text)
        guard doc.isRich else { return nil }
        return MarkdownLayoutEngine.layout(doc, source: text, maxWidth: Metrics(width: width).maxTextWidth)
    }

    /// The display string of a text part (what selection offsets index and Copy returns), or nil
    /// when the part takes the plain path (then the source is the display string). Independent of
    /// the width (only line breaks depend on it); thread safe; block layouts are cached.
    static func displayText(_ text: String, message: ID?, format: MessageFormat?) -> String? {
        layout(text, message: message, format: format, width: Fixture.windowWidth)?.plain
    }

    /// Measure-key salt: a message shown as source is a new measurement.
    static func versionSalt(_ id: ID) -> Int { MarkdownStore.shared.showsSource(id) ? 0x5EED : 0 }
}
