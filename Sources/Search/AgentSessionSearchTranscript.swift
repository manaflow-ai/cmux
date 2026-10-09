import CmuxAgentChat
import Foundation

/// The searchable text of one agent session, read incrementally from its
/// transcript JSONL.
///
/// `refresh()` reads only the bytes appended since the previous call and
/// parses the complete lines with the agent's own transcript parser. A file
/// that shrank or was replaced (new inode) restarts the read from the top.
/// The first read covers at most the last `initialReadByteLimit` bytes, so a
/// very long session costs one bounded read.
///
/// `refresh()` does blocking file I/O; `AgentSessionSearchTranscripts` runs
/// it on a dedicated queue, never on the main actor.
struct AgentSessionSearchTranscript: Sendable {
    static let initialReadByteLimit: UInt64 = 32 * 1024 * 1024
    /// Lines handed to the parser per call, to keep one batch's strings bounded.
    static let parseBatchLineCount = 2_000
    /// Longer lines are skipped unparsed. They carry image or file payloads in
    /// tool results (about 70% of the bytes of the largest transcripts measured
    /// on 2026-09-30) whose text the parser would clamp to 16 KB anyway.
    static let maxParsedLineBytes = 256 * 1024

    let path: String
    let agentKind: ChatAgentKind
    private(set) var text = AgentSessionSearchText()

    private var byteOffset: UInt64 = 0
    private var fileInode: UInt64?
    private var pendingFragment = Data()
    private var lineCount = 0
    private var parseState = ChatTranscriptParseState()

    init(path: String, agentKind: ChatAgentKind) {
        self.path = path
        self.agentKind = agentKind
    }

    /// Reads what the transcript gained since the last call.
    ///
    /// - Returns: Whether the searchable text changed.
    @discardableResult
    mutating func refresh() -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let inode = Self.inode(ofPath: path)
        let replaced = fileInode != nil && inode != nil && inode != fileInode
        var didReset = false
        if size < byteOffset || replaced {
            self = AgentSessionSearchTranscript(path: path, agentKind: agentKind)
            didReset = true
        }
        fileInode = inode
        guard size > byteOffset else { return didReset }

        var start = byteOffset
        var skipsPartialFirstLine = false
        if byteOffset == 0, size > Self.initialReadByteLimit {
            start = size - Self.initialReadByteLimit
            skipsPartialFirstLine = true
        }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return didReset }
        byteOffset = start + UInt64(data.count)

        let buffer: Data
        if pendingFragment.isEmpty {
            buffer = data
        } else {
            var joined = pendingFragment
            joined.append(data)
            buffer = joined
        }
        let split = Self.completeLines(in: buffer, dropsFirstLine: skipsPartialFirstLine)
        pendingFragment = split.remainder
        let lines = split.lines
        guard !lines.isEmpty else { return didReset }

        let entriesBefore = text.appendedEntryCount
        var batchStart = 0
        while batchStart < lines.count {
            let batchEnd = min(batchStart + Self.parseBatchLineCount, lines.count)
            let result = parse(lines: lines[batchStart..<batchEnd], startingSeq: lineCount + batchStart)
            parseState = result.state
            text.append(result)
            batchStart = batchEnd
        }
        lineCount += lines.count
        return didReset || text.appendedEntryCount != entriesBefore
    }

    /// Splits `buffer` at newlines with `memchr`, so a 32 MB first read does
    /// not walk `Data` byte by byte. Lines over `maxParsedLineBytes` are
    /// dropped; the bytes after the last newline come back as the remainder.
    static func completeLines(in buffer: Data, dropsFirstLine: Bool) -> (lines: [String], remainder: Data) {
        buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> ([String], Data) in
            guard let base = raw.baseAddress else { return ([], Data()) }
            var lines: [String] = []
            var lineStart = 0
            var dropsNextLine = dropsFirstLine
            while lineStart < raw.count,
                  let found = memchr(base + lineStart, 0x0A, raw.count - lineStart) {
                let newline = base.distance(to: found)
                let length = newline - lineStart
                if dropsNextLine {
                    dropsNextLine = false
                } else if length <= maxParsedLineBytes {
                    let bytes = UnsafeRawBufferPointer(start: base + lineStart, count: length)
                    lines.append(String(decoding: bytes, as: UTF8.self))
                }
                lineStart = newline + 1
            }
            let remainder = lineStart < raw.count
                ? Data(bytes: base + lineStart, count: raw.count - lineStart)
                : Data()
            return (lines, remainder)
        }
    }

    private func parse(lines: ArraySlice<String>, startingSeq: Int) -> ChatTranscriptParseResult {
        switch agentKind {
        case .codex:
            return CodexTranscriptParser().parse(lines: lines, startingSeq: startingSeq, state: parseState)
        case .claude, .other:
            return ClaudeTranscriptParser().parse(lines: lines, startingSeq: startingSeq, state: parseState)
        }
    }

    private static func inode(ofPath path: String) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attributes[.systemFileNumber] as? UInt64
    }
}

/// Bounded text collected from parsed transcript messages.
///
/// Prompts the user typed are the strongest search signal and stay longest:
/// they keep up to `promptByteLimit` UTF-8 bytes, oldest dropped first.
/// Agent replies and tool traffic keep the newest `otherByteLimit` bytes.
/// The first prompt is kept apart so the session's opening ask survives both
/// limits.
struct AgentSessionSearchText: Equatable, Sendable {
    static let promptByteLimit = 100_000
    static let otherByteLimit = 300_000

    private(set) var firstPrompt: String?
    /// Entries appended so far, so a reader can tell whether a parse added text.
    private(set) var appendedEntryCount = 0
    private var prompts = BoundedTextQueue(byteLimit: promptByteLimit)
    private var others = BoundedTextQueue(byteLimit: otherByteLimit)

    var isEmpty: Bool { firstPrompt == nil && prompts.isEmpty && others.isEmpty }

    /// The document text: the first prompt, then prompts newest first, then
    /// replies and tool traffic newest first.
    var documentText: String {
        ([firstPrompt].compactMap { $0 } + prompts.newestFirst + others.newestFirst)
            .joined(separator: "\n")
    }

    mutating func append(_ result: ChatTranscriptParseResult) {
        for message in result.messages {
            guard let entry = Self.entry(for: message) else { continue }
            if entry.isPrompt {
                if firstPrompt == nil { firstPrompt = entry.text }
                prompts.append(entry.text)
            } else {
                others.append(entry.text)
            }
            appendedEntryCount += 1
        }
        // Completed tool runs re-emit their message with the output filled in;
        // only the output is new.
        for message in result.updatedMessages {
            if let output = Self.completedOutput(of: message) {
                others.append(output)
                appendedEntryCount += 1
            }
        }
    }

    static func entry(for message: ChatMessage) -> (isPrompt: Bool, text: String)? {
        let parts: [String?]
        var isPrompt = false
        switch message.kind {
        case .prose(let prose):
            isPrompt = message.role == .user
            parts = [prose.text]
        case .toolUse(let tool):
            parts = [tool.toolName, tool.summary, tool.inputDetail, tool.output]
        case .terminal(let capture):
            parts = [capture.command, capture.output]
        case .fileEdit(let edit):
            parts = [edit.filePath]
        case .question(let question):
            parts = [question.prompt] + question.options.map(\.label)
        case .permissionRequest(let request):
            parts = [request.title, request.subject]
        case .thought, .status, .attachment, .unsupported:
            return nil
        }
        let text = parts
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return text.isEmpty ? nil : (isPrompt, text)
    }

    static func completedOutput(of message: ChatMessage) -> String? {
        let output: String?
        switch message.kind {
        case .toolUse(let tool):
            output = tool.output
        case .terminal(let capture):
            output = capture.output
        default:
            output = nil
        }
        let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Oldest-first text entries that drop from the front past a UTF-8 byte limit.
/// The newest entry always stays, even when it alone is over the limit.
struct BoundedTextQueue: Equatable, Sendable {
    let byteLimit: Int
    private var entries: [String] = []
    private var head = 0
    private var bytes = 0

    init(byteLimit: Int) {
        self.byteLimit = byteLimit
    }

    var isEmpty: Bool { head == entries.count }

    var newestFirst: [String] { entries[head...].reversed() }

    mutating func append(_ text: String) {
        entries.append(text)
        bytes += text.utf8.count
        while bytes > byteLimit, head < entries.count - 1 {
            bytes -= entries[head].utf8.count
            head += 1
        }
        // Compact once the dropped prefix outgrows the live entries.
        if head > 64, head * 2 > entries.count {
            entries.removeFirst(head)
            head = 0
        }
    }

    static func == (lhs: BoundedTextQueue, rhs: BoundedTextQueue) -> Bool {
        lhs.byteLimit == rhs.byteLimit
            && lhs.bytes == rhs.bytes
            && lhs.entries[lhs.head...].elementsEqual(rhs.entries[rhs.head...])
    }
}
