import Foundation

/// Lazily decodes one bounded transcript line at a time.
struct AgentChatTranscriptBoundedLineIterator: IteratorProtocol {
    let data: Data
    let maximumLineCount: Int
    var cursor: Data.Index
    var emittedLineCount = 0

    mutating func next() -> String? {
        guard emittedLineCount < maximumLineCount,
              cursor < data.endIndex else {
            return nil
        }
        let start = cursor
        while cursor < data.endIndex, data[cursor] != 0x0A {
            cursor = data.index(after: cursor)
        }
        let end = cursor
        if cursor < data.endIndex {
            cursor = data.index(after: cursor)
        }
        emittedLineCount += 1
        return String(decoding: data[start..<end], as: UTF8.self)
    }
}
