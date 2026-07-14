import CmuxAgentReplica
import CmuxAgentTruthKit
import CmuxFoundation
import Foundation

@MainActor
final class AgentGUIJournalPipeline {
    let sessionID: AgentSessionID
    private let kind: AgentKind
    private let path: String
    private var decoder: AgentGUITranscriptDecoderBox
    private var minter = JournalMinter()
    private var bookkeeper = AgentGUIJournalBookkeeper()
    private var toolPairingIndex = AgentGUIToolPairingIndex()
    private var currentIdentity: JournalIdentity?
    private var currentByteOffset = 0
    private var currentLineIndex = 0
    private var pendingPartialLine = Data()
    private var baselineFirstLine: String?
    private var inFlightIngestTask: Task<[AgentGUIJournalPipelineEvent], Never>?
    private var watcher: FileWatcher?
    private var watchTask: Task<Void, Never>?
    private(set) var window: AgentGUIJournalWindow?
    private(set) var isWatching = false
    private(set) var lastReadByteCount = 0
    private(set) var lastReadFailed = false

    init(sessionID: AgentSessionID, kind: AgentKind, path: String) {
        self.sessionID = sessionID
        self.kind = kind
        self.path = path
        self.decoder = AgentGUITranscriptDecoderBox(kind: kind)
    }

    func setWatching(_ shouldWatch: Bool, onEvents: @escaping @MainActor ([AgentGUIJournalPipelineEvent]) -> Void) {
        guard shouldWatch != isWatching else { return }
        isWatching = shouldWatch
        if shouldWatch {
            startWatching(onEvents: onEvents)
        } else {
            stopWatching()
        }
    }

    func ingestInitial() async -> [AgentGUIJournalPipelineEvent] {
        await ingest(fullRefresh: window == nil)
    }

    func entries(beforeSeq: EntrySeq?, afterSeq: EntrySeq?, limit: Int) -> (journalID: JournalID, entries: [EntrySnapshot], windowStart: EntrySeq, windowEnd: EntrySeq, tailSeq: EntrySeq, hasMoreBefore: Bool)? {
        guard !lastReadFailed, let window else { return nil }
        let entries = window.page(beforeSeq: beforeSeq, afterSeq: afterSeq, limit: limit)
        let start = entries.first?.seq ?? window.tailSeq
        let end = entries.last?.seq ?? window.tailSeq
        return (window.journalID, entries, start, end, window.tailSeq, window.hasMoreBefore(for: entries))
    }

    private func startWatching(onEvents: @escaping @MainActor ([AgentGUIJournalPipelineEvent]) -> Void) {
        let watcher = FileWatcher(path: path, throttle: AgentGUIConstants.journalWatchCoalescing)
        self.watcher = watcher
        watchTask = Task { @MainActor [weak self] in
            for await _ in watcher.events {
                guard let self else { return }
                let events = await self.ingest(fullRefresh: false)
                guard !events.isEmpty else { continue }
                onEvents(events)
            }
        }
    }

    private func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        if let watcher {
            Task { await watcher.stop() }
        }
        watcher = nil
    }

    private func ingest(fullRefresh: Bool) async -> [AgentGUIJournalPipelineEvent] {
        if let inFlightIngestTask {
            return await inFlightIngestTask.value
        }
        let task = Task { @MainActor [self] in
            await performIngest(fullRefresh: fullRefresh)
        }
        inFlightIngestTask = task
        let events = await task.value
        inFlightIngestTask = nil
        return events
    }

    private func performIngest(fullRefresh: Bool) async -> [AgentGUIJournalPipelineEvent] {
        let capturedIdentity: AgentGUIFileIdentity
        switch await fileIdentity() {
        case .success(let captured):
            capturedIdentity = captured
        case .failure(let error) where error.code == .ENOENT || error.code == .ENOTDIR:
            lastReadFailed = false
            guard window == nil else { return [] }
            let journalID = JournalID(rawValue: "pending:\(sessionID.rawValue)")
            window = AgentGUIJournalWindow(journalID: journalID)
            return [.reset(journalID: journalID, tailSeq: EntrySeq(rawValue: 0))]
        case .failure:
            lastReadFailed = true
            return []
        }
        let shrankInPlace = capturedIdentity.size < currentByteOffset
        let identity = capturedIdentity.journalIdentity(
            baselineFirstLine: baselineFirstLine,
            forceHeadTruncated: shrankInPlace
        )
        let decision = minter.decide(previous: currentIdentity, current: identity, currentJournalID: window?.journalID)
        let journalID: JournalID
        let didReset: Bool
        switch decision {
        case .same(let existing):
            journalID = existing
            didReset = false
        case .created(let created):
            journalID = created
            didReset = true
        }

        let chunk = if didReset || fullRefresh {
            await readInitialTail()
        } else {
            await readChunk(from: currentByteOffset)
        }
        guard chunk.readSucceeded else {
            lastReadFailed = true
            return []
        }
        lastReadFailed = false
        if didReset {
            decoder = AgentGUITranscriptDecoderBox(kind: kind)
            bookkeeper.reset()
            toolPairingIndex.reset()
            currentByteOffset = 0
            currentLineIndex = 0
            pendingPartialLine.removeAll(keepingCapacity: true)
            baselineFirstLine = capturedIdentity.firstLine
            currentIdentity = capturedIdentity.journalIdentity(baselineFirstLine: baselineFirstLine)
        }
        lastReadByteCount = chunk.data.count
        if didReset || fullRefresh {
            let result = rebuildWindow(journalID: journalID, from: chunk)
            currentByteOffset = chunk.endOffset
            return result
        }

        guard chunk.byteCount > 0 else { return [] }
        currentByteOffset = chunk.endOffset
        return append(data: chunk.data, journalID: journalID)
    }

    private func decode(lines: [String], startingAt: Int, journalID: JournalID) -> [AgentGUIStampedEntry] {
        let batch = decoder.feed(lines, startingAt: startingAt, journalID: journalID)
        return batch.entries.map { entry in
            bookkeeper.stamp(toolPairingIndex.normalize(entry))
        }
    }

    private func apply(_ stamped: [AgentGUIStampedEntry]) -> [AgentGUIJournalPipelineEvent] {
        guard !stamped.isEmpty else { return [] }
        if window == nil {
            window = AgentGUIJournalWindow(journalID: stamped[0].entry.journalID)
        }
        var appended: [EntrySnapshot] = []
        var events: [AgentGUIJournalPipelineEvent] = []
        for item in stamped {
            window?.apply(item.entry)
            if item.isReplacement {
                if !appended.isEmpty {
                    events.append(.appended(journalID: item.entry.journalID, entries: appended))
                    appended.removeAll()
                }
                events.append(.replaced(journalID: item.entry.journalID, entry: item.entry))
            } else {
                appended.append(item.entry)
            }
        }
        if !appended.isEmpty, let journalID = appended.first?.journalID {
            events.append(.appended(journalID: journalID, entries: appended))
        }
        return events
    }

    private func rebuildWindow(journalID: JournalID, from chunk: ReadChunk) -> [AgentGUIJournalPipelineEvent] {
        let lines = consumeCompleteLines(from: chunk.data)
        let cappedStart = max(0, lines.count - AgentGUIConstants.initialTailLineCap)
        let completeLines = Array(lines.dropFirst(cappedStart))
        let stamped = decode(lines: completeLines, startingAt: cappedStart, journalID: journalID)
        currentLineIndex = cappedStart + completeLines.count
        var nextWindow = AgentGUIJournalWindow(journalID: journalID)
        nextWindow.reset(
            journalID: journalID,
            entries: stamped.map(\.entry),
            hasMoreBefore: chunk.discardedPrefix || cappedStart > 0
        )
        window = nextWindow
        return [.reset(journalID: journalID, tailSeq: nextWindow.tailSeq)]
    }

    private func append(data: Data, journalID: JournalID) -> [AgentGUIJournalPipelineEvent] {
        let lines = consumeCompleteLines(from: data)
        guard !lines.isEmpty else { return [] }
        let stamped = decode(lines: lines, startingAt: currentLineIndex, journalID: journalID)
        currentLineIndex += lines.count
        return apply(stamped)
    }

    private func fileIdentity() async -> Result<AgentGUIFileIdentity, POSIXError> {
        let path = path
        return await Task.detached(priority: .utility) {
            AgentGUIFileIdentity.capture(path: path)
        }.value
    }

    private func readChunk(from byteOffset: Int) async -> ReadChunk {
        let path = path
        return await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
                return ReadChunk(data: Data(), endOffset: byteOffset, discardedPrefix: false, readSucceeded: false)
            }
            defer { try? handle.close() }
            do { try handle.seek(toOffset: UInt64(byteOffset)) } catch {
                return ReadChunk(data: Data(), endOffset: byteOffset, discardedPrefix: false, readSucceeded: false)
            }
            do {
                let data = try handle.readToEnd() ?? Data()
                return ReadChunk(data: data, endOffset: byteOffset + data.count, discardedPrefix: false, readSucceeded: true)
            } catch {
                return ReadChunk(data: Data(), endOffset: byteOffset, discardedPrefix: false, readSucceeded: false)
            }
        }.value
    }

    private func readInitialTail() async -> ReadChunk {
        let path = path
        return await Task.detached(priority: .utility) {
            AgentGUITranscriptTailReader.read(
                path: path,
                lineLimit: AgentGUIConstants.initialTailLineCap,
                byteLimit: AgentGUIConstants.initialTailByteCap
            )
        }.value
    }

    private func consumeCompleteLines(from data: Data) -> [String] {
        var bytes = pendingPartialLine
        bytes.append(data)
        var lines: [String] = []
        var lineStart = bytes.startIndex
        for index in bytes.indices where bytes[index] == 0x0A {
            lines.append(String(decoding: bytes[lineStart..<index], as: UTF8.self))
            lineStart = bytes.index(after: index)
        }
        pendingPartialLine = Data(bytes[lineStart...])
        return lines
    }
}

private struct ReadChunk: Sendable {
    let data: Data
    let endOffset: Int
    let discardedPrefix: Bool
    let readSucceeded: Bool
    var byteCount: Int { data.count }
}

private enum AgentGUITranscriptTailReader {
    static func read(path: String, lineLimit: Int, byteLimit: Int) -> ReadChunk {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return ReadChunk(data: Data(), endOffset: 0, discardedPrefix: false, readSucceeded: false)
        }
        defer { try? handle.close() }
        let endOffset = Int((try? handle.seekToEnd()) ?? 0)
        let startOffset = max(0, endOffset - max(1, byteLimit))
        do { try handle.seek(toOffset: UInt64(startOffset)) } catch {
            return ReadChunk(data: Data(), endOffset: endOffset, discardedPrefix: startOffset > 0, readSucceeded: false)
        }
        let readData: Data
        do {
            readData = try handle.readToEnd() ?? Data()
        } catch {
            return ReadChunk(data: Data(), endOffset: endOffset, discardedPrefix: startOffset > 0, readSucceeded: false)
        }
        var data = readData
        var discardedPrefix = startOffset > 0
        if startOffset > 0 {
            if let firstNewline = data.firstIndex(of: 0x0A) {
                data = Data(data[data.index(after: firstNewline)...])
            } else {
                data.removeAll()
            }
        }
        let newlineIndexes = data.indices.filter { data[$0] == 0x0A }
        if newlineIndexes.count > lineLimit {
            let cutoff = newlineIndexes[newlineIndexes.count - lineLimit - 1]
            data = Data(data[data.index(after: cutoff)...])
            discardedPrefix = true
        }
        return ReadChunk(data: data, endOffset: endOffset, discardedPrefix: discardedPrefix, readSucceeded: true)
    }
}
