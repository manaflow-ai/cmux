import Foundation

/// What Search All Windows looks through, read once when it opens: every
/// tab's title and place, every terminal's history and screen (from its
/// daemon, on any machine), and the transcript of each Claude Code or Codex
/// session in a terminal on this Mac. Each keystroke searches this copy off
/// the main actor, so typing never reads a daemon or a file.
package nonisolated struct GlobalSearchCorpus: Sendable {
    /// One tab to search, as the main actor describes it.
    package nonisolated struct Source: Sendable {
        package let tabID: String
        /// The tab's title, its workspace's name and a browser's address.
        package let title: String
        package let terminal: TerminalTextSearch.Target?
        package let agent: AgentTranscriptText.Session?
        /// A terminal whose daemon is not connected: searched by title, counted as not read.
        package var disconnected = false
        /// Read from this Mac (its daemon or transcript file): read before other machines' terminals.
        package var local = true

        package init(tabID: String, title: String, terminal: TerminalTextSearch.Target?, agent: AgentTranscriptText.Session?,
                     disconnected: Bool = false, local: Bool = true) {
            self.tabID = tabID
            self.title = title
            self.terminal = terminal
            self.agent = agent
            self.disconnected = disconnected
            self.local = local
        }
    }

    /// Where a content match was found.
    package nonisolated enum Origin: Sendable, Equatable {
        case terminal
        /// The agent session's transcript (`claude`, `codex`).
        case transcript(String)
    }

    package nonisolated struct Content: Sendable {
        package let origin: Origin
        /// Non-empty trimmed lines, oldest first.
        package let lines: [String]
        package let lowered: [String]

        package init(origin: Origin, lines raw: [String]) {
            self.origin = origin
            let lines = raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            self.lines = lines
            lowered = lines.map { $0.lowercased() }
        }
    }

    package nonisolated struct Document: Sendable {
        package let tabID: String
        package let title: String
        package let loweredTitle: String
        /// The transcript first: its text is what was said, a TUI's history is redraws.
        package let texts: [Content]
    }

    /// One tab's match.
    package nonisolated struct Hit: Sendable, Equatable {
        package let tabID: String
        /// The newest line with the query's words, nil when the title alone matched.
        package let line: String?
        package let origin: Origin?
        /// Matching lines in all of the tab's text.
        package let count: Int
        package let titleMatched: Bool
    }

    package var documents: [Document] = []
    /// Terminals whose text could not be read.
    package var unreadable = 0

    /// Rows shown in all.
    package static let limit = 200

    package static func words(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// A transcript's lines with this process's environment: `load`'s default reader, a named
    /// function because an async closure literal as a parameter default can corrupt the heap (cx-bsue).
    @concurrent package static func transcriptLines(of session: AgentTranscriptText.Session) async -> [String]? {
        await AgentTranscriptText.lines(of: session)
    }

    /// One source's text, as `reads` delivers it.
    package nonisolated struct Read: Sendable {
        package let index: Int
        package let texts: [Content]
        package let unreadable: Bool

        package init(index: Int, texts: [Content], unreadable: Bool) {
            self.index = index
            self.texts = texts
            self.unreadable = unreadable
        }
    }

    package init() {}

    /// Every source with its title and no text yet: what a search finds before any read lands.
    package init(titles sources: [Source]) {
        documents = sources.map { Document(tabID: $0.tabID, title: $0.title, loweredTitle: $0.title.lowercased(), texts: []) }
        unreadable = sources.count(where: \.disconnected)
    }

    /// The corpus with `read`'s text in its source's place.
    package mutating func apply(_ read: Read) {
        guard documents.indices.contains(read.index) else { return }
        let document = documents[read.index]
        documents[read.index] = Document(tabID: document.tabID, title: document.title, loweredTitle: document.loweredTitle,
                                         texts: read.texts)
        if read.unreadable { unreadable += 1 }
    }

    /// Reads every source: terminals `TerminalTextSearch.concurrentReads` at
    /// a time, transcripts alongside. A cancelled task stops queueing reads.
    @concurrent package static func load(
        _ sources: [Source],
        read: @escaping @Sendable (TerminalTextSearch.Target) async -> [String]? = TerminalTextSearch.lines(of:),
        transcript: @escaping @Sendable (AgentTranscriptText.Session) async -> [String]? = transcriptLines(of:)
    ) async -> GlobalSearchCorpus {
        var corpus = GlobalSearchCorpus(titles: sources)
        for await done in reads(sources, read: read, transcript: transcript) { corpus.apply(done) }
        return corpus
    }

    /// Each source's text as soon as it is read, in the order the reads end: terminals
    /// `TerminalTextSearch.concurrentReads` at a time, transcripts alongside, sources on this
    /// Mac first (a slow machine's daemon never holds up the others). Sources with nothing to
    /// read yield nothing. Ending the stream (its consumer cancelled) stops queueing reads.
    package static func reads(
        _ sources: [Source],
        read: @escaping @Sendable (TerminalTextSearch.Target) async -> [String]? = TerminalTextSearch.lines(of:),
        transcript: @escaping @Sendable (AgentTranscriptText.Session) async -> [String]? = transcriptLines(of:)
    ) -> AsyncStream<Read> {
        // One read per source at most: the buffer never drops one.
        let (stream, continuation) = AsyncStream.makeStream(of: Read.self, bufferingPolicy: .bufferingOldest(max(1, sources.count)))
        // task-owner: the stream's consumer; onTermination cancels it, which stops queueing reads.
        let task = Task {
            await withTaskGroup(of: Read.self) { group in
                let ordered = sources.indices.filter { sources[$0].terminal != nil || sources[$0].agent != nil }
                    .sorted { (sources[$0].local ? 0 : 1, $0) < (sources[$1].local ? 0 : 1, $1) }
                var queue = ordered.makeIterator()
                func next() -> Bool {
                    guard let index = queue.next() else { return false }
                    let source = sources[index]
                    group.addTask {
                        var found: [Content] = []
                        if let agent = source.agent, let lines = await transcript(agent) {
                            found.append(Content(origin: .transcript(agent.harness), lines: lines))
                        }
                        var unreadable = false
                        if let terminal = source.terminal {
                            if let lines = await read(terminal) {
                                found.append(Content(origin: .terminal, lines: lines))
                            } else {
                                unreadable = true
                            }
                        }
                        return Read(index: index, texts: found, unreadable: unreadable)
                    }
                    return true
                }
                for _ in 0..<TerminalTextSearch.concurrentReads {
                    guard next() else { break }
                }
                for await done in group {
                    continuation.yield(done)
                    if !Task.isCancelled { _ = next() }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// The tabs matching every word, at most `limit`: a word may match the
    /// title and the rest one line of the tab's text. Tabs whose title
    /// holds every word come first, then the others in source order.
    @concurrent package func hits(_ words: [String], limit: Int = GlobalSearchCorpus.limit) async -> (hits: [Hit], limited: Bool) {
        guard !words.isEmpty else { return ([], false) }
        var titled: [Hit] = []
        var others: [Hit] = []
        for document in documents {
            if Task.isCancelled { break }
            let remaining = words.filter { !document.loweredTitle.contains($0) }
            var best: (line: String, origin: Origin)?
            var count = 0
            for text in document.texts {
                let needs = remaining.isEmpty ? words : remaining
                for index in text.lowered.indices.reversed() where needs.allSatisfy({ text.lowered[index].contains($0) }) {
                    if best == nil { best = (text.lines[index], text.origin) }
                    count += 1
                }
            }
            if remaining.isEmpty {
                titled.append(Hit(tabID: document.tabID, line: best?.line, origin: best?.origin, count: count, titleMatched: true))
            } else if let best {
                others.append(Hit(tabID: document.tabID, line: best.line, origin: best.origin, count: count, titleMatched: false))
            }
        }
        let all = titled + others
        return (Array(all.prefix(limit)), all.count > limit)
    }

    /// `line` cut to about `before` characters ahead of the first word and
    /// `after` from it, with an ellipsis where it was cut.
    package static func snippet(_ line: String, words: [String], before: Int = 48, after: Int = 110) -> String {
        guard let word = words.first(where: { line.range(of: $0, options: .caseInsensitive) != nil }),
              let range = line.range(of: word, options: .caseInsensitive) else {
            return line.count > before + after ? String(line.prefix(before + after)) + "…" : line
        }
        let start = line.index(range.lowerBound, offsetBy: -before, limitedBy: line.startIndex) ?? line.startIndex
        let end = line.index(range.lowerBound, offsetBy: after, limitedBy: line.endIndex) ?? line.endIndex
        return (start > line.startIndex ? "…" : "") + line[start..<end] + (end < line.endIndex ? "…" : "")
    }

    /// The word Find highlights: the first query word in the line, as typed there.
    package static func needle(in line: String, words: [String]) -> String {
        guard let word = words.first(where: { line.range(of: $0, options: .caseInsensitive) != nil }) ?? words.first else { return "" }
        guard let range = line.range(of: word, options: .caseInsensitive) else { return word }
        return String(line[range])
    }
}
