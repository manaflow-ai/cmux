import Foundation

// cmux: HomeProjection maps the whole shown window on every HomeStore update (HomeDiff's checks and
// a rebuild): a streaming Chief reply that grows a word at a time spent about 23 ms of main thread
// per word, most of it in `TextParts.parts` (its NSDataDetector) and Markdown for messages that did
// not change (round 4 capture, Time Profiler trace B). Both are pure functions of the text, so
// their results are kept per text; only a text that changed is split and rendered again.

/// A bounded, thread-safe map from a text to a value made from it alone.
final class TextMemo<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Value] = [:]
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func value(_ text: String, _ make: (String) -> Value) -> Value {
        lock.lock()
        if let v = values[text] { lock.unlock(); return v }
        lock.unlock()
        let v = make(text)
        lock.lock()
        if values.count >= limit { values.removeAll(keepingCapacity: true) }
        values[text] = v
        lock.unlock()
        return v
    }
}

extension HomeMapping {
    private static let textPartsMemo = TextMemo<[Part]>(limit: 256)
    private static let markdownMemo = TextMemo<(text: String, runs: [TextRun])>(limit: 256)

    /// `TextParts.parts(for:)` (Messages' link rule), kept per text.
    static func textParts(_ text: String) -> [Part] { textPartsMemo.value(text) { TextParts.parts(for: $0) } }

    /// `HomeMarkdown.render`, kept per text.
    static func markdown(_ text: String) -> (text: String, runs: [TextRun]) { markdownMemo.value(text) { HomeMarkdown.render($0) } }
}
