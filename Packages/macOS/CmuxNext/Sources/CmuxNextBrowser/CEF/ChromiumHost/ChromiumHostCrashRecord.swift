#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug and bench builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextCompat
public import Foundation

/// One end of the Chromium Host that was not a clean exit (task 085 of plans/cmux-next/chrome-parity/p01-process.md),
/// for `debug.crashes` and the crash report folder: how it ended, what it ran and the last lines of its Chromium log.
/// As Chrome's crash keys (components/crash/core/common/crash_key.h), it holds no page content: every URL in the log
/// lines is replaced (``scrubbed(_:)``), and no title or typed text is kept.
public nonisolated struct ChromiumHostCrashRecord: Sendable, Equatable {
    /// The log lines a record keeps, newest last.
    public static let logTailLines = 20
    /// The bytes read from the log's end for them.
    static let logTailBytes = 16 * 1024
    /// The longest log line kept, in characters.
    static let lineLimit = 400
    /// What stands in for a URL in a log line.
    static let urlMark = "<url>"
    /// Schemes whose URLs have no `//` (`data:text/html,...`); the others are found by their `://`.
    static let opaqueSchemes = ["about:", "blob:", "data:", "filesystem:", "javascript:", "mailto:", "view-source:"]

    public var date: Date
    public var pid: Int32
    /// The signal that ended it (SIGTRAP for a CHECK, SIGSEGV, SIGKILL), nil for an exit.
    public var signal: Int32?
    /// Its exit status, nil for a signal.
    public var exitCode: Int32?
    /// The crash state of its end (``ChromiumHostExit/pageExit``): crashed, killed, abnormal or launchFailed.
    public var reason: BrowserProcessExit.Reason
    /// Why it could not start (``ChromiumHostExit/startFailure``), nil for any other end.
    public var startFailure: String?
    /// It said hello: its end was a crash of its pages. An end before the hello is a failed start.
    public var saidHello: Bool
    /// The version the Chromium framework's Info.plist names, nil when it could not be read.
    public var cefVersion: String?
    /// The host's Chromium fork API (its remote shim's mirror), nil when it ended before cmux read it.
    public var forkAPI: Int32?
    /// The last lines of its log (`chromium-host.log`), newest last, URLs replaced.
    public var logTail: [String]

    public init(date: Date, pid: Int32, signal: Int32?, exitCode: Int32?, reason: BrowserProcessExit.Reason,
                startFailure: String?, saidHello: Bool, cefVersion: String?, forkAPI: Int32?, logTail: [String]) {
        self.date = date
        self.pid = pid
        self.signal = signal
        self.exitCode = exitCode
        self.reason = reason
        self.startFailure = startFailure
        self.saidHello = saidHello
        self.cefVersion = cefVersion
        self.forkAPI = forkAPI
        self.logTail = logTail
    }

    /// The signal's name (`SIGTRAP`), nil for an exit.
    public var signalName: String? {
        signal.map { BrowserProcessExit.signalName(Int($0)) ?? "signal \($0)" }
    }

    /// The last ``logTailLines`` lines of `file` (``logTail(_:startsMidLine:)``), from at most its last
    /// ``logTailBytes`` bytes; none when it cannot be read. Blocks: on a lane.
    static func logTail(of file: URL) -> [String] {
        guard let handle = blockingCall(.fileIO, { try? FileHandle(forReadingFrom: file) }) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.blockingSeekToEnd() else { return [] }
        let limit = UInt64(logTailBytes)
        let start = size > limit ? size - limit : 0
        guard (try? handle.blockingSeek(toOffset: start)) != nil,
              let data = try? handle.blockingRead(upToCount: Int(size - start)) else { return [] }
        return logTail(data, startsMidLine: start > 0)
    }

    /// The last ``logTailLines`` lines of `data`, the end of a log, with blank lines left out and each line
    /// ``scrubbed(_:)``. `startsMidLine`: `data` begins inside a line (a read from the middle of the file), whose
    /// start is not there, so that first line is left out.
    static func logTail(_ data: Data, startsMidLine: Bool) -> [String] {
        var lines = String(decoding: data, as: UTF8.self).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if startsMidLine, !lines.isEmpty { lines.removeFirst() }
        return lines.filter { !$0.allSatisfy(\.isWhitespace) }.suffix(logTailLines).map(scrubbed)
    }

    /// `line` with each URL in it replaced by ``urlMark`` from its scheme to the end of its word, then cut to
    /// ``lineLimit`` characters. A URL is a word part with a scheme and `://`, or one that starts with an
    /// ``opaqueSchemes`` scheme. Chromium logs a page's URL in a navigation or a console message.
    static func scrubbed(_ line: Substring) -> String {
        let words = line.split(separator: " ", omittingEmptySubsequences: false).map { word in
            urlStart(in: word).map { String(word[..<$0]) + urlMark } ?? String(word)
        }
        let text = words.joined(separator: " ")
        return text.count > lineLimit ? String(text.prefix(lineLimit - 1)) + "…" : text
    }

    /// Where the first URL in `word` starts, nil when it has none.
    private static func urlStart(in word: Substring) -> Substring.Index? {
        guard let separator = word.range(of: "://") else { return opaqueURLStart(in: word) }
        var start = separator.lowerBound
        while start > word.startIndex, isSchemeCharacter(word[word.index(before: start)]) {
            start = word.index(before: start)
        }
        return opaqueURLStart(in: word[..<start]) ?? start
    }

    /// Where the first URL of an ``opaqueSchemes`` scheme in `text` starts: the scheme at a word part's start.
    private static func opaqueURLStart(in text: Substring) -> Substring.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let partStart = index == text.startIndex || !isSchemeCharacter(text[text.index(before: index)])
            let rest = text[index...]
            if partStart, opaqueSchemes.contains(where: { rest.prefix($0.count).lowercased() == $0 }) { return index }
            index = text.index(after: index)
        }
        return nil
    }

    private static func isSchemeCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "+" || character == "-" || character == ".")
    }
}
#endif
