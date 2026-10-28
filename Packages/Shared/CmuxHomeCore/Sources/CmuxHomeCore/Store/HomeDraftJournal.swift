import CmuxSafeConcurrency
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The write-ahead record of Home drafts (audit 4, P15): each draft change, as it is typed, is
/// appended to `<index>-drafts.journal` beside the cache's index, so a forced end of the app (a crash,
/// a SIGKILL, a power loss, Force Quit), which runs no quit step and loses the cache's coalesced
/// batch, loses no draft. ``HomeCache/load()`` replays the record over the index. A cache write that
/// holds every change up to a number (``mark``) lets the record drop those lines
/// (``settle(through:)``), so the file holds only what the index does not have yet: the app's 250 ms
/// batch, usually nothing.
///
/// One line per change, `{"c":<conversation>,"n":<number>,"t":<text or null>}` and a newline, appended
/// with one `write(2)` (`O_APPEND`) on a serial queue of its own: never the caller's thread, never the
/// cache actor's, so an index write in progress does not hold a keystroke's line. A line cut short by
/// the end of the process does not decode; the next launch's first append or settle rewrites the
/// file without it.
///
/// Numbers count this launch's changes from 1. Lines an earlier launch left are number 0: older than
/// any change of this launch, and held by any cache state taken after the store restored from
/// ``HomeCache/load()`` (which replayed them), so the first such write drops them.
///
/// ```swift
/// let number = journal.record("half a thought", for: conversation)  // at once; the line is written on the queue
/// journal.settle(through: number)                                    // after a cache write that holds it
/// let drafts = journal.replay(over: snapshot.drafts)
/// ```
public final class HomeDraftJournal: Sendable {
    /// The record file.
    public let url: URL
    /// The record's own queue (one small append per change; the person waits on none of it).
    private let queue = DispatchQueue(label: "com.cmuxterm.home.drafts-journal", qos: .userInitiated)
    /// The last number handed out, and the lines in the file (queue only) with their numbers.
    private let state = Mutex(State())

    private struct State: Sendable {
        var number: UInt64 = 0
        var lines: [Entry] = []
        /// The file left by an earlier launch was read (queue only).
        var primed = false
    }

    private struct Entry: Sendable {
        var number: UInt64
        var bytes: Data
    }

    private struct Line: Codable {
        var c: String
        var n: UInt64
        var t: String?
    }

    public init(url: URL) {
        self.url = url
    }

    /// The newest number handed out: a cache state taken now holds every change up to it.
    public var mark: UInt64 { state.withLock { $0.number } }

    /// Appends `text` (nil or empty: no draft) for `conversation` as the next line, on the record's
    /// queue; returns its number at once.
    @discardableResult
    public func record(_ text: String?, for conversation: ConversationID) -> UInt64 {
        let number = state.withLock { state -> UInt64 in
            state.number &+= 1
            return state.number
        }
        let line = Line(c: conversation.rawValue, n: number, t: text.flatMap { $0.isEmpty ? nil : $0 })
        queue.async { [self] in append(line) }
        return number
    }

    /// A cache write that holds every change up to `number` (and the earlier launch's lines) reached
    /// disk: those lines go; the file keeps the later ones (typed while the write ran), none empties it.
    public func settle(through number: UInt64) {
        queue.async { [self] in
            prime()
            let kept: [Data]? = state.withLock { state in
                guard state.lines.contains(where: { $0.number <= number }) else { return nil }
                state.lines.removeAll { $0.number <= number }
                return state.lines.map(\.bytes)
            }
            guard let kept else { return }
            rewrite(kept)
        }
    }

    /// Returns once every line and settle handed to the queue so far is done (tests).
    public func idle() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
    }

    /// `drafts` with the record's changes on top, in order: what was typed after the index was
    /// written. Reads the file on the caller's thread (the cache's launch read); nil when it holds none.
    public func replay(over drafts: [ConversationID: String]) -> [ConversationID: String]? {
        let lines = Self.lines(in: (try? Data(contentsOf: url)) ?? Data()).lines
        guard !lines.isEmpty else { return nil }
        var drafts = drafts
        for line in lines { drafts[ConversationID(line.c)] = line.t }
        return drafts
    }

    // MARK: Queue

    private func append(_ line: Line) {
        prime()
        guard var bytes = try? JSONEncoder().encode(line) else { return }
        bytes.append(0x0A)
        guard write(bytes) else { return }
        state.withLock { $0.lines.append(Entry(number: line.n, bytes: bytes)) }
    }

    /// Once per launch, before the first append or settle: the earlier launch's whole lines, as number 0.
    /// A file that ends in a line cut short is rewritten without it, so the next line is not glued to it.
    private func prime() {
        guard !state.withLock({ $0.primed }) else { return }
        let data = (try? Data(contentsOf: url)) ?? Data()
        let found = Self.lines(in: data)
        let old = found.lines.compactMap { line -> Entry? in
            guard var bytes = try? JSONEncoder().encode(line) else { return nil }
            bytes.append(0x0A)
            return Entry(number: 0, bytes: bytes)
        }
        state.withLock { state in
            state.primed = true
            state.lines = old + state.lines
        }
        if !found.whole { rewrite(old.map(\.bytes)) }
    }

    private func rewrite(_ lines: [Data]) {
        if lines.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? HomeCache.atomicWrite(Data(lines.joined()), to: url)
        }
    }

    /// One `write(2)` of a whole line with `O_APPEND`: a process end leaves at most the last line cut short.
    private func write(_ bytes: Data) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let written = bytes.withUnsafeBytes { buffer in
            #if canImport(Darwin)
            Darwin.write(fd, buffer.baseAddress, buffer.count)
            #else
            Glibc.write(fd, buffer.baseAddress, buffer.count)
            #endif
        }
        return written == bytes.count
    }

    /// The lines of `data` that decode, up to the first that does not; `whole` when that is all of it.
    private static func lines(in data: Data) -> (lines: [Line], whole: Bool) {
        var lines: [Line] = []
        let decoder = JSONDecoder()
        for chunk in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let line = try? decoder.decode(Line.self, from: Data(chunk)) else { return (lines, false) }
            lines.append(line)
        }
        return (lines, data.isEmpty || data.last == 0x0A)
    }
}
