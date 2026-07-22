import CmuxAgentReplica
import CmuxAgentTruthKit
import CmuxFoundation
import Foundation

struct AgentGUIJournalDecodedPage: Sendable {
    let journalID: JournalID
    let entries: [EntrySnapshot]
    let startOffset: Int
    let endOffset: Int
    let tailOffset: Int
    let tailSeq: EntrySeq
    let hasMoreBefore: Bool
    let hasMoreAfter: Bool
}

@MainActor
final class AgentGUIJournalPipeline {
    let sessionID: AgentSessionID
    private let kind: AgentKind
    private let path: String
    private let imageStore: AgentGUITranscriptImageStore
    private let decodeWorker: AgentGUITranscriptDecodeWorker
    private var minter = JournalMinter()
    private var bookkeeper = AgentGUIJournalBookkeeper()
    private var toolPairingIndex = AgentGUIToolPairingIndex()
    private var currentIdentity: JournalIdentity?
    private var currentByteOffset = 0
    private var pendingPartialLine = Data()
    private var pendingPartialLineStartOffset = 0
    private var baselineFirstLine: String?
    private var toolCallLinesByID: [String: AgentGUIJournalSourceLine] = [:]
    private var toolCallCacheOrder: [String] = []
    private var inFlightIngestTask: Task<[AgentGUIJournalPipelineEvent], Never>?
    private var watcher: FileWatcher?
    private var watchTask: Task<Void, Never>?
    private(set) var window: AgentGUIJournalWindow?
    private(set) var isWatching = false
    private(set) var lastReadByteCount = 0
    private(set) var lastReadFailed = false

    init(
        sessionID: AgentSessionID,
        kind: AgentKind,
        path: String,
        imageStore: AgentGUITranscriptImageStore = .shared
    ) {
        self.sessionID = sessionID
        self.kind = kind
        self.path = path
        self.imageStore = imageStore
        self.decodeWorker = AgentGUITranscriptDecodeWorker(kind: kind)
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

    var currentJournalID: JournalID? {
        window?.journalID
    }

    func diskEntries(direction: AgentGUIJournalPageDirection, limit: Int) async -> AgentGUIJournalDecodedPage? {
        guard !lastReadFailed, let window else { return nil }
        let path = path
        let rawLineLimit = max(limit, limit * AgentGUIConstants.journalPageRawLineMultiplier)
        let rawPage = await Task.detached(priority: .utility) {
            AgentGUIJournalPageReader.read(
                path: path,
                direction: direction,
                lineLimit: rawLineLimit,
                byteLimit: AgentGUIConstants.journalPageByteCap
            )
        }.value
        guard rawPage.readSucceeded else { return nil }
        var contextLines: [AgentGUIJournalSourceLine]
        if rawPage.startOffset > 0 {
            let contextPage = await Task.detached(priority: .utility) {
                AgentGUIJournalPageReader.read(
                    path: path,
                    direction: .before(rawPage.startOffset),
                    lineLimit: AgentGUIConstants.journalPageContextLineCap,
                    byteLimit: AgentGUIConstants.journalPageContextByteCap
                )
            }.value
            contextLines = contextPage.readSucceeded ? contextPage.lines : []
        } else {
            contextLines = []
        }
        let rawPageLines = rawPage.lines
        let resultIDs = await Task.detached(priority: .utility) {
            Set(rawPageLines.flatMap { AgentGUIJournalToolCorrelation.resultIDs(in: $0.text) })
        }.value
        if !resultIDs.isEmpty, rawPage.startOffset > 0 {
            var located: [String: AgentGUIJournalSourceLine] = [:]
            for callID in resultIDs {
                if let cached = toolCallLinesByID[callID], cached.startOffset < rawPage.startOffset {
                    located[callID] = cached
                }
            }
            let missing = resultIDs.subtracting(located.keys)
            if !missing.isEmpty {
                let discovered = await Task.detached(priority: .utility) {
                    AgentGUIJournalToolCallLocator.locate(
                        callIDs: missing,
                        path: path,
                        before: rawPage.startOffset
                    )
                }.value
                for (callID, sourceLine) in discovered.linesByCallID {
                    located[callID] = sourceLine
                    cacheToolCall(callID: callID, sourceLine: sourceLine)
                }
            }
            var existingOffsets = Set(contextLines.map(\.startOffset))
            for sourceLine in located.values where existingOffsets.insert(sourceLine.startOffset).inserted {
                contextLines.append(sourceLine)
            }
            contextLines.sort { $0.startOffset < $1.startOffset }
        }

        struct LocatedEntry {
            let entry: EntrySnapshot
            let sourceStart: Int
            let sourceEnd: Int
        }
        let pageDecodeWorker = AgentGUITranscriptDecodeWorker(kind: kind)
        var pageBookkeeper = AgentGUIJournalBookkeeper()
        var pagePairingIndex = AgentGUIToolPairingIndex()
        var locatedEntries: [LocatedEntry] = []
        var embeddedImages: [TranscriptEmbeddedImage] = []
        let contextBatches = await pageDecodeWorker.feed(contextLines, journalID: window.journalID)
        for decodedLine in contextBatches {
            for decoded in decodedLine.batch.entries {
                _ = pageBookkeeper.stamp(pagePairingIndex.normalize(decoded))
            }
        }
        let rawBatches = await pageDecodeWorker.feed(rawPage.lines, journalID: window.journalID)
        for decodedLine in rawBatches {
            cacheToolCalls(
                in: decodedLine.sourceLine,
                callIDs: decodedLine.toolCallIDs
            )
            embeddedImages.append(contentsOf: decodedLine.batch.embeddedImages)
            for decoded in decodedLine.batch.entries {
                let stamped = pageBookkeeper.stamp(pagePairingIndex.normalize(decoded)).entry
                locatedEntries.append(LocatedEntry(
                    entry: stamped,
                    sourceStart: decodedLine.sourceLine.startOffset,
                    sourceEnd: decodedLine.sourceLine.endOffset
                ))
            }
        }
        let ordered = locatedEntries.sorted { lhs, rhs in
            if lhs.sourceStart != rhs.sourceStart { return lhs.sourceStart < rhs.sourceStart }
            if lhs.entry.seq != rhs.entry.seq { return lhs.entry.seq < rhs.entry.seq }
            return lhs.entry.version < rhs.entry.version
        }
        let selected: [LocatedEntry]
        switch direction {
        case .tail, .before:
            let suffix = ordered.suffix(limit)
            if let boundary = suffix.first?.sourceStart {
                selected = ordered.filter { $0.sourceStart >= boundary }
            } else {
                selected = []
            }
        case .head, .after:
            let prefix = ordered.prefix(limit)
            if let boundary = prefix.last?.sourceStart {
                selected = ordered.filter { $0.sourceStart <= boundary }
            } else {
                selected = []
            }
        }
        let startOffset: Int
        let endOffset: Int
        if selected.isEmpty {
            startOffset = rawPage.startOffset
            endOffset = rawPage.endOffset
        } else {
            startOffset = selected.map(\.sourceStart).min() ?? rawPage.startOffset
            endOffset = selected.map(\.sourceEnd).max() ?? rawPage.endOffset
        }
        let resolvedEntries = await resolveImages(
            in: selected.map(\.entry),
            embeddedImages: embeddedImages
        )
        let committedTailOffset = pendingPartialLine.isEmpty ? currentByteOffset : pendingPartialLineStartOffset
        return AgentGUIJournalDecodedPage(
            journalID: window.journalID,
            entries: resolvedEntries,
            startOffset: startOffset,
            endOffset: endOffset,
            tailOffset: committedTailOffset,
            tailSeq: window.tailSeq,
            hasMoreBefore: rawPage.hasMoreBefore || startOffset > 0,
            hasMoreAfter: endOffset < committedTailOffset
        )
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

        let shouldRebaseToTail = !didReset
            && !fullRefresh
            && capturedIdentity.size - currentByteOffset > AgentGUIConstants.journalIncrementalByteCap
        let chunk = if didReset || fullRefresh || shouldRebaseToTail {
            await readInitialTail()
        } else {
            await readChunk(from: currentByteOffset)
        }
        guard chunk.readSucceeded else {
            lastReadFailed = true
            return []
        }
        lastReadFailed = false
        if didReset || shouldRebaseToTail {
            await decodeWorker.reset()
            if didReset {
                await AgentChatArtifactIndex.shared.removeSupplementalAttachments(
                    sessionID: sessionID.rawValue
                )
            }
            bookkeeper.reset()
            toolPairingIndex.reset()
            toolCallLinesByID.removeAll(keepingCapacity: true)
            toolCallCacheOrder.removeAll(keepingCapacity: true)
            currentByteOffset = 0
            pendingPartialLine.removeAll(keepingCapacity: true)
            pendingPartialLineStartOffset = 0
            if didReset {
                baselineFirstLine = capturedIdentity.firstLine
                currentIdentity = capturedIdentity.journalIdentity(baselineFirstLine: baselineFirstLine)
            }
        }
        lastReadByteCount = chunk.data.count
        if didReset || fullRefresh || shouldRebaseToTail {
            let result = await rebuildWindow(journalID: journalID, from: chunk)
            currentByteOffset = chunk.endOffset
            return result
        }

        guard chunk.byteCount > 0 else { return [] }
        currentByteOffset = chunk.endOffset
        return await append(data: chunk.data, startingAt: chunk.startOffset, journalID: journalID)
    }

    private func decode(
        sourceLines: [AgentGUIJournalSourceLine],
        journalID: JournalID
    ) async -> [AgentGUIStampedEntry] {
        var decodedEntries: [EntrySnapshot] = []
        var embeddedImages: [TranscriptEmbeddedImage] = []
        let decodedLines = await decodeWorker.feed(sourceLines, journalID: journalID)
        for decodedLine in decodedLines {
            cacheToolCalls(
                in: decodedLine.sourceLine,
                callIDs: decodedLine.toolCallIDs
            )
            decodedEntries.append(contentsOf: decodedLine.batch.entries)
            embeddedImages.append(contentsOf: decodedLine.batch.embeddedImages)
        }
        let resolvedEntries = await resolveImages(
            in: decodedEntries,
            embeddedImages: embeddedImages
        )
        return resolvedEntries.map { entry in
            bookkeeper.stamp(toolPairingIndex.normalize(entry))
        }
    }

    private func resolveImages(
        in entries: [EntrySnapshot],
        embeddedImages: [TranscriptEmbeddedImage]
    ) async -> [EntrySnapshot] {
        guard !entries.isEmpty else { return [] }
        let entryKeys = Set(entries.map {
            AgentGUITranscriptImageEntryKey(journalID: $0.journalID, sequence: $0.seq)
        })
        let relevantEmbeddedImages = embeddedImages.filter {
            entryKeys.contains(AgentGUITranscriptImageEntryKey(
                journalID: $0.journalID,
                sequence: $0.entrySeq
            ))
        }
        let referencedImages = entries.compactMap { entry -> AgentGUITranscriptImageStore.ReferencedImage? in
            guard case .attachment(let attachment) = entry.content.payload,
                  attachment.mimeType?.hasPrefix("image/") == true
                    || attachment.kind.lowercased().contains("image"),
                  let hostPath = attachment.hostPath,
                  !hostPath.isEmpty else { return nil }
            return AgentGUITranscriptImageStore.ReferencedImage(
                entrySeq: entry.seq,
                path: hostPath,
                mimeType: attachment.mimeType
            )
        }
        var resolvedImages = await imageStore.inspect(referencedImages)
        let materializedImages = await imageStore.materialize(relevantEmbeddedImages)
        resolvedImages.merge(materializedImages) { _, materialized in materialized }
        let resolved = entries.map { entry -> EntrySnapshot in
            guard case .attachment(let attachment) = entry.content.payload,
                  let image = resolvedImages[entry.seq] else { return entry }
            let payload = EntryPayload.attachment(AttachmentPayload(
                kind: attachment.kind,
                summary: attachment.summary,
                attachmentID: attachment.attachmentID,
                displayName: attachment.displayName,
                hostPath: image.path,
                mimeType: image.mimeType,
                byteCount: image.byteCount,
                width: image.width,
                height: image.height
            ))
            return EntrySnapshot(
                journalID: entry.journalID,
                seq: entry.seq,
                kind: entry.kind,
                content: EntryContent(contentHash: payload.stableHash, payload: payload),
                version: entry.version,
                timestampMilliseconds: entry.timestampMilliseconds
            )
        }
        let attachments = resolvedImages.map { sequence, image in
            return AgentChatArtifactIndex.SupplementalAttachment(
                path: image.path,
                sourceSeq: sequence.rawValue
            )
        }
        if !attachments.isEmpty {
            await AgentChatArtifactIndex.shared.registerAttachments(
                sessionID: sessionID.rawValue,
                transcriptPath: path,
                attachments: attachments
            )
        }
        return resolved
    }

    private func cacheToolCalls(
        in sourceLine: AgentGUIJournalSourceLine,
        callIDs: Set<String>
    ) {
        for callID in callIDs {
            cacheToolCall(callID: callID, sourceLine: sourceLine)
        }
    }

    private func cacheToolCall(callID: String, sourceLine: AgentGUIJournalSourceLine) {
        if toolCallLinesByID[callID] == nil {
            toolCallCacheOrder.append(callID)
        }
        toolCallLinesByID[callID] = sourceLine
        while toolCallCacheOrder.count > AgentGUIConstants.journalToolCallCacheCap {
            let evicted = toolCallCacheOrder.removeFirst()
            toolCallLinesByID[evicted] = nil
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

    private func rebuildWindow(
        journalID: JournalID,
        from chunk: ReadChunk
    ) async -> [AgentGUIJournalPipelineEvent] {
        let lines = await consumeCompleteLines(from: chunk.data, startingAt: chunk.startOffset)
        let stamped = await decode(sourceLines: lines, journalID: journalID)
        var nextWindow = AgentGUIJournalWindow(journalID: journalID)
        nextWindow.reset(
            journalID: journalID,
            entries: stamped.map(\.entry),
            hasMoreBefore: chunk.discardedPrefix || stamped.count > AgentGUIConstants.journalWindowEntryCap
        )
        window = nextWindow
        return [.reset(journalID: journalID, tailSeq: nextWindow.tailSeq)]
    }

    private func append(
        data: Data,
        startingAt byteOffset: Int,
        journalID: JournalID
    ) async -> [AgentGUIJournalPipelineEvent] {
        let lines = await consumeCompleteLines(from: data, startingAt: byteOffset)
        guard !lines.isEmpty else { return [] }
        let stamped = await decode(sourceLines: lines, journalID: journalID)
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
                return ReadChunk(data: Data(), startOffset: byteOffset, endOffset: byteOffset, discardedPrefix: false, readSucceeded: false)
            }
            defer { try? handle.close() }
            do { try handle.seek(toOffset: UInt64(byteOffset)) } catch {
                return ReadChunk(data: Data(), startOffset: byteOffset, endOffset: byteOffset, discardedPrefix: false, readSucceeded: false)
            }
            do {
                let data = try handle.readToEnd() ?? Data()
                return ReadChunk(data: data, startOffset: byteOffset, endOffset: byteOffset + data.count, discardedPrefix: false, readSucceeded: true)
            } catch {
                return ReadChunk(data: Data(), startOffset: byteOffset, endOffset: byteOffset, discardedPrefix: false, readSucceeded: false)
            }
        }.value
    }

    private func readInitialTail() async -> ReadChunk {
        let path = path
        return await Task.detached(priority: .utility) {
            AgentGUITranscriptTailReader.read(
                path: path,
                lineLimit: AgentGUIConstants.initialTailLineCap + AgentGUIConstants.journalPageContextLineCap,
                byteLimit: AgentGUIConstants.initialTailByteCap
            )
        }.value
    }

    private func consumeCompleteLines(
        from data: Data,
        startingAt byteOffset: Int
    ) async -> [AgentGUIJournalSourceLine] {
        let priorPending = pendingPartialLine
        let priorPendingStartOffset = pendingPartialLineStartOffset
        let frame = await Task.detached(priority: .utility) {
            AgentGUIJournalLineFramer.consume(
                pendingData: priorPending,
                pendingStartOffset: priorPendingStartOffset,
                data: data,
                startOffset: byteOffset
            )
        }.value
        pendingPartialLine = frame.pendingData
        pendingPartialLineStartOffset = frame.pendingStartOffset
        return frame.lines
    }
}

private struct AgentGUITranscriptImageEntryKey: Hashable {
    let journalID: JournalID
    let sequence: EntrySeq
}

private struct AgentGUIJournalLineFrame: Sendable {
    let lines: [AgentGUIJournalSourceLine]
    let pendingData: Data
    let pendingStartOffset: Int
}

private enum AgentGUIJournalLineFramer {
    static func consume(
        pendingData: Data,
        pendingStartOffset: Int,
        data: Data,
        startOffset: Int
    ) -> AgentGUIJournalLineFrame {
        let combinedStartOffset = pendingData.isEmpty ? startOffset : pendingStartOffset
        var bytes = pendingData
        bytes.append(data)
        var lines: [AgentGUIJournalSourceLine] = []
        var lineStart = bytes.startIndex
        for index in bytes.indices where bytes[index] == 0x0A {
            let next = bytes.index(after: index)
            let relativeStart = bytes.distance(from: bytes.startIndex, to: lineStart)
            let relativeEnd = bytes.distance(from: bytes.startIndex, to: next)
            lines.append(AgentGUIJournalSourceLine(
                text: String(decoding: bytes[lineStart ..< index], as: UTF8.self),
                startOffset: combinedStartOffset + relativeStart,
                endOffset: combinedStartOffset + relativeEnd
            ))
            lineStart = next
        }
        return AgentGUIJournalLineFrame(
            lines: lines,
            pendingData: Data(bytes[lineStart...]),
            pendingStartOffset: combinedStartOffset
                + bytes.distance(from: bytes.startIndex, to: lineStart)
        )
    }
}

private struct ReadChunk: Sendable {
    let data: Data
    let startOffset: Int
    let endOffset: Int
    let discardedPrefix: Bool
    let readSucceeded: Bool
    var byteCount: Int { data.count }
}

private enum AgentGUITranscriptTailReader {
    static func read(path: String, lineLimit: Int, byteLimit: Int) -> ReadChunk {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return ReadChunk(data: Data(), startOffset: 0, endOffset: 0, discardedPrefix: false, readSucceeded: false)
        }
        defer { try? handle.close() }
        let endOffset = Int((try? handle.seekToEnd()) ?? 0)
        let startOffset = max(0, endOffset - max(1, byteLimit))
        let startsAtLineBoundary: Bool
        if startOffset == 0 {
            startsAtLineBoundary = true
        } else {
            do {
                try handle.seek(toOffset: UInt64(startOffset - 1))
                startsAtLineBoundary = try handle.read(upToCount: 1)?.first == 0x0A
            } catch {
                startsAtLineBoundary = false
            }
        }
        do { try handle.seek(toOffset: UInt64(startOffset)) } catch {
            return ReadChunk(data: Data(), startOffset: startOffset, endOffset: endOffset, discardedPrefix: startOffset > 0, readSucceeded: false)
        }
        let readData: Data
        do {
            readData = try handle.readToEnd() ?? Data()
        } catch {
            return ReadChunk(data: Data(), startOffset: startOffset, endOffset: endOffset, discardedPrefix: startOffset > 0, readSucceeded: false)
        }
        var data = readData
        var dataStartOffset = startOffset
        var discardedPrefix = startOffset > 0
        if startOffset > 0, !startsAtLineBoundary {
            if let firstNewline = data.firstIndex(of: 0x0A) {
                let next = data.index(after: firstNewline)
                dataStartOffset += data.distance(from: data.startIndex, to: next)
                data = Data(data[next...])
            } else {
                dataStartOffset = endOffset
                data.removeAll()
            }
        }
        let newlineIndexes = data.indices.filter { data[$0] == 0x0A }
        if newlineIndexes.count > lineLimit {
            let cutoff = newlineIndexes[newlineIndexes.count - lineLimit - 1]
            let next = data.index(after: cutoff)
            dataStartOffset += data.distance(from: data.startIndex, to: next)
            data = Data(data[next...])
            discardedPrefix = true
        }
        return ReadChunk(data: data, startOffset: dataStartOffset, endOffset: endOffset, discardedPrefix: discardedPrefix, readSucceeded: true)
    }
}
