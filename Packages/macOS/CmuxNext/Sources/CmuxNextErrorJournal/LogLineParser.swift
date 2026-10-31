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
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let range = NSRange(line.startIndex..., in: line)
            let date = Self.date(in: line) ?? Date()
            if let match = Self.panic?.firstMatch(in: line, range: range),
               let frameRange = Range(match.range(at: 1), in: line), let restRange = Range(match.range(at: 2), in: line) {
                var message = String(line[restRange]).trimmingCharacters(in: .whitespaces)
                if message.isEmpty, index < lines.count {
                    message = lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                }
                events.append(ErrorEvent(source: source, level: .fault, message: "panic: \(message)",
                                         topFrame: String(line[frameRange]), context: ["file": file], date: date))
                continue
            }
            guard let match = Self.level?.firstMatch(in: line, range: range),
                  let levelRange = Range(match.range(at: 1), in: line) else { continue }
            let word = line[levelRange]
            let level: ErrorLevel = switch word {
            case "WARN", "WARNING": .warning
            case "ERROR": .error
            default: .fault
            }
            let message = line[levelRange.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " :]-\t"))
            events.append(ErrorEvent(source: source, level: level, message: message.isEmpty ? line : message,
                                     context: ["file": file], date: date))
        }
        return events
    }

    private static func date(in line: String) -> Date? {
        guard let match = timestamp?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: String(line[range])) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: String(line[range]))
    }
}
