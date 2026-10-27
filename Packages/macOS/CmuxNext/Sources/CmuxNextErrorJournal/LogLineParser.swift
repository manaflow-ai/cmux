import Foundation

/// Finds problems in log text: `tracing` lines (`<time>  WARN target: message`), any line with a
/// `WARN`/`WARNING`/`ERROR`/`FATAL` level word, and Rust panics.
struct LogLineParser {
    let source: String
    let file: String

    // Constant patterns (ErrorJournalTests); were one ever to fail to compile, its rule finds
    // nothing rather than crash the journal.
    private static let ansi = try? NSRegularExpression(pattern: #"\x1b\[[0-9;]*[A-Za-z]"#)
    private static let level = try? NSRegularExpression(pattern: #"\b(WARN|WARNING|ERROR|FATAL|CRITICAL)\b"#)
    private static let panic = try? NSRegularExpression(pattern: #"panicked at ([^\s:]+:\d+)(?::\d+)?:?\s*(.*)$"#)
    private static let timestamp = try? NSRegularExpression(pattern: #"^\s*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)"#)

    func events(in text: String) -> [ErrorEvent] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let line = String(line)
            return Self.ansi?.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "") ?? line
        }
        var events: [ErrorEvent] = []
        var rest = ArraySlice(lines)
        while let line = rest.popFirst() {
            let range = NSRange(line.startIndex..., in: line)
            let date = Self.date(in: line) ?? Date()
            if let match = Self.panic?.firstMatch(in: line, range: range),
               let frame = match.capture(1, in: line), let tail = match.capture(2, in: line) {
                var message = tail.trimmingCharacters(in: .whitespaces)
                if message.isEmpty, let next = rest.popFirst() {
                    message = next.trimmingCharacters(in: .whitespaces)
                }
                events.append(ErrorEvent(source: source, level: .fault, message: "panic: \(message)",
                                         topFrame: frame, context: ["file": file], date: date))
                continue
            }
            guard let match = Self.level?.firstMatch(in: line, range: range),
                  let word = match.capture(1, in: line), let after = match.text(after: 1, in: line) else { continue }
            let level: ErrorLevel = switch word {
            case "WARN", "WARNING": .warning
            case "ERROR": .error
            default: .fault
            }
            let message = after.trimmingCharacters(in: CharacterSet(charactersIn: " :]-\t"))
            events.append(ErrorEvent(source: source, level: level, message: message.isEmpty ? line : message,
                                     context: ["file": file], date: date))
        }
        return events
    }

    private static func date(in line: String) -> Date? {
        guard let match = timestamp?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let stamp = match.capture(1, in: line) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: stamp) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: stamp)
    }
}
