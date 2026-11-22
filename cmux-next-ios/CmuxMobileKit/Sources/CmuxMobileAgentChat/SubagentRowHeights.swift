#if os(iOS)
import SwiftUI
import UIKit

/// The heights of a subagent transcript's tall answers, measured once with the view that draws
/// them and pinned on their rows. A lazy stack measures a row only when it builds it, and a
/// 15,000 pt log answer re-measured under the reader moved the transcript (SUB-11's tall row);
/// pinned, the row's height is known before it is built and never changes while it is read.
///
/// Measured when the answer's text arrives or the width or text size changes (the screen's
/// `.task`), never in a body pass and never on the frame that scrolls the row in. The text is
/// SwiftUI's (`StreamingMarkdown`), so it is measured on the main thread by hosting that view.
@MainActor
final class SubagentRowHeights {
    /// Answers longer than this (UTF-8 bytes) are measured and pinned; shorter ones are cheap
    /// for the lazy stack to measure as it builds them.
    nonisolated static let tallBytes = 4000

    struct Key: Hashable {
        var width: CGFloat
        var size: DynamicTypeSize
    }

    private struct Entry {
        var markdown: String
        var key: Key
        var height: CGFloat
    }

    private var entries: [String: Entry] = [:]
    /// Measurements made (tests: once per answer, width and text size).
    private(set) var measures = 0
    /// Main-thread time spent measuring, in seconds.
    private(set) var measureSeconds: Double = 0

    static func isTall(_ markdown: String) -> Bool { markdown.utf8.count > tallBytes }

    /// The pinned height of row `id`, when its text, width and size were measured.
    func height(_ id: String, markdown: String, key: Key) -> CGFloat? {
        guard let entry = entries[id], entry.key == key, entry.markdown == markdown else { return nil }
        return entry.height
    }

    /// Measures the tall, finished answers in `rows` not measured for `key` yet; true when one
    /// was. `live` is the streaming answer's id (its text changes per token: never pinned).
    @discardableResult
    func measure(_ rows: [TurnRow], key: Key, live: String?) -> Bool {
        guard key.width > 0 else { return false }
        var measured = false
        var seen = Set<String>()
        for row in rows {
            guard case .message(let id, let markdown) = row, id != live, Self.isTall(markdown) else { continue }
            seen.insert(id)
            if height(id, markdown: markdown, key: key) != nil { continue }
            let start = Date()
            let size = Self.drawnSize(markdown, key: key)
            measureSeconds += Date().timeIntervalSince(start)
            measures += 1
            entries[id] = Entry(markdown: markdown, key: key, height: size.height)
            measured = true
        }
        entries = entries.filter { seen.contains($0.key) }
        return measured
    }

    /// The answer as the transcript draws it (`StreamingMarkdown`, finished), at `key`.
    static func drawnSize(_ markdown: String, key: Key) -> CGSize {
        let host = UIHostingController(rootView: answer(markdown, key: key))
        host.sizingOptions = []
        return host.sizeThatFits(in: CGSize(width: key.width, height: .greatestFiniteMagnitude))
    }

    /// The view `SubagentRowView` draws for a finished answer, at the key's text size.
    static func answer(_ markdown: String, key: Key) -> some View {
        StreamingMarkdown(markdown: markdown, isStreaming: false)
            .environment(\.dynamicTypeSize, key.size)
            .frame(width: key.width, alignment: .leading)
    }
}
#endif
