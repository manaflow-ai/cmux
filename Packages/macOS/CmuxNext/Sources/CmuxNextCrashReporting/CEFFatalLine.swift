import CmuxNextCompat
public import Foundation

/// The `FATAL` line Chromium wrote just before it aborted the process that ran `CefInitialize`, as the crash
/// event's `cef.fatal` tag (plans/cmux-next/chrome-parity/p09-observability.md, task 084).
///
/// Chromium's log prefix is `[pid:tid:MMDD/HHMMSS.us:SEVERITY:path:line] message` (`path(line)` in older
/// builds; base/logging.cc, `LogMessage::Init`). Only the last `FATAL` line of the log's tail is kept, as
/// `FATAL:<path>:<line>] ` plus at most ``maxMessageCharacters`` of its message, after every URL in the
/// message became `<url>`: a page's address never leaves the Mac. Chrome puts the same message on the
/// crash report as its `LOG_FATAL` crash key (base/logging.cc).
///
/// ```swift
/// let line = CEFFatalLine(log: "[1:2:1027/101010.1:FATAL:content/a.cc:42] Check failed: https://x.test")
/// line?.tagValue  // "FATAL:content/a.cc:42] Check failed: <url>"
/// ```
public struct CEFFatalLine: Sendable, Equatable {
    /// The crash event tag that carries ``tagValue``.
    public static let tag = "cef.fatal"
    /// The bytes read from the end of the log.
    public static let maxTailBytes = 64 * 1024
    /// The message characters kept after `]`.
    public static let maxMessageCharacters = 120
    /// The source path characters kept (its end), so the tag stays under Sentry's 200-character tag limit.
    public static let maxPathCharacters = 60

    /// The source file, as Chromium printed it with no leading `../`.
    public let path: String
    /// The source line.
    public let line: Int
    /// The message with URLs removed, at most ``maxMessageCharacters`` characters.
    public let message: String

    /// The last `FATAL` line of `log` written by process `pid`; nil when it has none. Every Chromium process of a
    /// run writes to the same log (CEF passes `--log-file` to its helpers), so a renderer's `FATAL` is skipped
    /// when the line names its pid. Nil `pid`, or a line with no pid field, takes any process's line.
    public init?(log: String, pid: Int32? = nil) {
        for candidate in log.split(whereSeparator: { $0.isNewline }).reversed() {
            if let parsed = Self(logLine: candidate, pid: pid) {
                self = parsed
                return
            }
        }
        return nil
    }

    /// One log line when its severity is `FATAL` and, when it names one, its pid is `pid`.
    init?(logLine: Substring, pid: Int32?) {
        guard logLine.first == "[", let close = logLine.firstIndex(of: "]") else { return nil }
        let header = logLine[logLine.index(after: logLine.startIndex) ..< close]
        let locationText: Substring
        if header.hasPrefix("FATAL:") {
            locationText = header.dropFirst("FATAL:".count)
        } else if let severity = header.range(of: ":FATAL:") {
            let firstField = header[..<(header.firstIndex(of: ":") ?? header.endIndex)]
            if let pid, let linePid = Int32(firstField), linePid != pid { return nil }
            locationText = header[severity.upperBound...]
        } else {
            return nil
        }
        guard let location = Self.location(locationText) else { return nil }
        var rest = logLine[logLine.index(after: close)...]
        if rest.first == " " { rest = rest.dropFirst() }
        path = location.path
        line = location.line
        message = String(Self.withoutURLs(rest).prefix(Self.maxMessageCharacters))
    }

    /// The tag's value: `FATAL:<path>:<line>] <message>`.
    public var tagValue: String {
        message.isEmpty ? "FATAL:\(path):\(line)]" : "FATAL:\(path):\(line)] \(message)"
    }

    /// `path:line` or `path(line)`, the path's leading `../` dropped and its end kept.
    private static func location(_ text: Substring) -> (path: String, line: Int)? {
        let pathEnd: Substring.Index
        let digits: Substring
        if text.last == ")", let open = text.lastIndex(of: "(") {
            pathEnd = open
            digits = text[text.index(after: open) ..< text.index(before: text.endIndex)]
        } else if let colon = text.lastIndex(of: ":") {
            pathEnd = colon
            digits = text[text.index(after: colon)...]
        } else {
            return nil
        }
        guard let line = Int(digits), line >= 0 else { return nil }
        var path = text[..<pathEnd]
        while path.hasPrefix("../") { path = path.dropFirst(3) }
        guard !path.isEmpty, !path.contains(where: { $0.isWhitespace }) else { return nil }
        return (String(path.suffix(maxPathCharacters)), line)
    }

    /// The URL schemes that name a resource without `//` (`data:`, `javascript:` and the like).
    private static let opaqueSchemes: Set<String> = ["about", "blob", "data", "file", "filesystem", "javascript", "mailto", "view-source"]

    /// `text` with every URL as `<url>`. A `scheme://` URL or a `www.` host runs to the next whitespace, or to the
    /// quote that opened it when a quote stands just before it, so an apostrophe in its path stays inside it. An
    /// opaque-scheme URL (``opaqueSchemes``: `data:`, `javascript:` and the like) can hold spaces and page content,
    /// so it and everything after it become one `<url>`. Stops once `limit` characters are written.
    static func withoutURLs(_ text: Substring, limit: Int = maxMessageCharacters) -> String {
        var output = ""
        var index = text.startIndex
        while index < text.endIndex, output.count < limit {
            let tokenEnd = text[index...].firstIndex(where: isTokenEnd) ?? text.endIndex
            guard tokenEnd != index else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }
            let token = text[index ..< tokenEnd]
            let quoteFollows = tokenEnd < text.endIndex && !text[tokenEnd].isWhitespace
            guard let url = urlStart(in: token, quoteFollows: quoteFollows) else {
                output += token
                index = tokenEnd
                continue
            }
            output += token[..<url.start]
            output += "<url>"
            if url.isOpaque { break }
            index = urlEnd(in: text, from: url.start)
        }
        return output
    }

    /// Where the hierarchical URL that starts at `start` ends: the next whitespace, or the next quote that matches a
    /// quote just before `start`.
    private static func urlEnd(in text: Substring, from start: Substring.Index) -> Substring.Index {
        let before: Character? = start > text.startIndex ? text[text.index(before: start)] : nil
        let closingQuote: Character? = before == "\"" || before == "'" ? before : nil
        return text[start...].firstIndex { $0.isWhitespace || $0 == closingQuote } ?? text.endIndex
    }

    /// Whitespace and quotes split the message into the tokens that ``urlStart(in:quoteFollows:)`` looks at.
    private static func isTokenEnd(_ character: Character) -> Bool {
        character.isWhitespace || character == "\"" || character == "'"
    }

    private static func isSchemeCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "+" || character == "-" || character == ".")
    }

    /// Where a URL starts in one space-free token (after any leading punctuation such as `(` or `=`) and whether its
    /// scheme is opaque, or nil. An opaque scheme with nothing after its `:` in the token counts only when a quote
    /// follows (`javascript:'...'`). One pass: each run of scheme characters is looked at once.
    private static func urlStart(in token: Substring, quoteFollows: Bool) -> (start: Substring.Index, isOpaque: Bool)? {
        var index = token.startIndex
        while index < token.endIndex {
            guard token[index].isASCII, token[index].isLetter else {
                index = token.index(after: index)
                continue
            }
            let runEnd = token[index...].firstIndex { !isSchemeCharacter($0) } ?? token.endIndex
            let run = token[index ..< runEnd].lowercased()
            if run.hasPrefix("www.") { return (index, false) }
            if runEnd < token.endIndex, token[runEnd] == ":" {
                let after = token[token.index(after: runEnd)...]
                if after.hasPrefix("//") { return (index, false) }
                if opaqueSchemes.contains(run), !after.isEmpty || quoteFollows { return (index, true) }
            }
            index = runEnd
        }
        return nil
    }

    /// The last `FATAL` line of process `pid` in the newest file in `candidates` whose last write falls in
    /// `window`: the log of the run that ended, never an older run's or this launch's. Reads at most
    /// ``maxTailBytes`` from the end of one file. Blocking file work: off the main thread.
    public static func read(candidates: [URL], writtenIn window: Range<Date>, pid: Int32?) -> CEFFatalLine? {
        let written = candidates.compactMap { url -> (url: URL, modified: Date)? in
            guard let modified = (try? FileManager.checked.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  window.contains(modified) else { return nil }
            return (url, modified)
        }
        for file in written.sorted(by: { $0.modified > $1.modified }) {
            guard let tail = tail(of: file.url) else { continue }
            return CEFFatalLine(log: tail, pid: pid)
        }
        return nil
    }

    /// The last ``maxTailBytes`` of `url` as text, from its first whole line; nil when it cannot be read.
    static func tail(of url: URL, maxBytes: Int = maxTailBytes) -> String? {
        guard let handle = try? FileHandle.blockingForReading(from: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.blockingSeekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.blockingSeek(toOffset: start)) != nil, let data = try? handle.blockingRead(upToCount: maxBytes) else {
            return nil
        }
        var bytes = data[...]
        // A read that starts inside a line drops that partial line.
        if start > 0, let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) { bytes = bytes[bytes.index(after: newline)...] }
        return String(decoding: bytes, as: UTF8.self)
    }
}
