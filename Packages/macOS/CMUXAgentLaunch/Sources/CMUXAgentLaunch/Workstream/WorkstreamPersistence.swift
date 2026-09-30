import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Default cap for the active JSONL file before it rotates.
public let WorkstreamDefaultMaxActiveFileBytes: UInt64 = 64 * 1024 * 1024

/// Append-only JSONL persistence for `WorkstreamItem`. One item per line.
///
/// Disk use is bounded: the active file (`workstream.jsonl`) rotates to a
/// single previous generation (`workstream.1.jsonl`) once the next append
/// would push it past `maxActiveFileBytes`, so the log never holds more
/// than about twice the cap. An older file that grew past the cap before
/// rotation existed is trimmed once to its newest line-aligned bytes. The
/// copy runs on a detached utility task so reads and appends never wait
/// for it; cursors into the old file are re-anchored after the swap, and
/// rows appended during the copy are carried into the trimmed file.
///
/// Writes are serialized through the actor so the store can fire them off
/// without awaiting disk IO. The write handle is reopened whenever the path
/// no longer names the file it points at, so `cmux feed clear` (which
/// unlinks the file from the CLI process) or a rotation by another app
/// instance never leaves this process appending to an unlinked inode.
public actor WorkstreamPersistence {
    /// Stable identity of one log file. A rename keeps it, so a cursor
    /// taken in the active file keeps pointing at the same rows after the
    /// file rotates to the previous generation.
    public struct FileIdentity: Sendable, Hashable, Codable {
        public let device: UInt64
        public let inode: UInt64
        public let birthSeconds: Int64
        public let birthNanoseconds: Int64
    }

    /// Position in the log: rows strictly before `offset` in `file`.
    /// A `nil` file is a legacy bare byte offset and means the active file.
    public struct Cursor: Sendable, Hashable, Codable {
        public let file: FileIdentity?
        public let offset: UInt64

        public init(file: FileIdentity?, offset: UInt64) {
            self.file = file
            self.offset = offset
        }

        private enum CodingKeys: String, CodingKey {
            case file
            case offset
        }

        public init(from decoder: any Decoder) throws {
            // Cursors used to be bare byte offsets into the active file.
            if let single = try? decoder.singleValueContainer(),
               let legacyOffset = try? single.decode(UInt64.self) {
                self.init(file: nil, offset: legacyOffset)
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                file: try container.decodeIfPresent(FileIdentity.self, forKey: .file),
                offset: try container.decode(UInt64.self, forKey: .offset)
            )
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(file, forKey: .file)
            try container.encode(offset, forKey: .offset)
        }
    }

    public struct Page: Sendable, Equatable {
        public let items: [WorkstreamItem]
        public let hasMoreBefore: Bool
        /// Pass back as `endingBefore` to load the rows before this page.
        public let startCursor: Cursor?

        /// Byte offset of the first row within its own file.
        public var startOffset: UInt64? { startCursor?.offset }

        public init(
            items: [WorkstreamItem],
            hasMoreBefore: Bool,
            startCursor: Cursor?
        ) {
            self.items = items
            self.hasMoreBefore = hasMoreBefore
            self.startCursor = startCursor
        }
    }

    private let fileURL: URL
    private let previousFileURL: URL
    private let maxActiveFileBytes: UInt64
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var handle: FileHandle?
    private var handleIdentity: FileIdentity?
    private var hasCheckedOversizedFile = false
    /// True from the trim's size snapshot until its swap or abandonment.
    /// Rotation waits so the oversized file is never moved whole into the
    /// previous generation.
    private var legacyTrimInFlight = false
    private var legacyTrimTask: Task<Void, Never>?
    private var legacyTrimFinalizeGate: (@Sendable () async -> Void)?
    /// Old file identity -> trimmed file identity and bytes dropped from
    /// its front, so cursors from before the trim keep their rows.
    private var reanchors: [FileIdentity: (file: FileIdentity, droppedBytes: UInt64)] = [:]

    /// - Parameters:
    ///   - fileURL: Active JSONL file. The previous generation lives next to
    ///     it with `.1` inserted before the extension.
    ///   - maxActiveFileBytes: Size at which the active file rotates.
    public init(
        fileURL: URL,
        maxActiveFileBytes: UInt64 = WorkstreamDefaultMaxActiveFileBytes
    ) {
        self.fileURL = fileURL
        self.previousFileURL = Self.previousGenerationURL(for: fileURL)
        self.maxActiveFileBytes = max(1, maxActiveFileBytes)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    /// Default JSONL path in the user's cmuxterm state directory.
    public static func defaultFileURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("workstream.jsonl", isDirectory: false)
    }

    /// Path of the single rotated generation for `fileURL`
    /// (`workstream.jsonl` -> `workstream.1.jsonl`).
    public static func previousGenerationURL(for fileURL: URL) -> URL {
        let ext = fileURL.pathExtension
        let base = fileURL.deletingPathExtension()
        let name = base.lastPathComponent + ".1" + (ext.isEmpty ? "" : "." + ext)
        return base.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
    }

    /// Appends a single item as a JSON line. Creates the file and parent
    /// directory lazily on first write, and rotates first when the line
    /// would push the active file past the cap.
    public func append(_ item: WorkstreamItem) throws {
        startLegacyTrimIfNeeded()
        let data = try encoder.encode(item.redactedForPersistence())
        var line = data
        line.append(0x0A) // "\n"
        var fh = try handleForWriting()
        let size = try Self.size(of: fh)
        if !legacyTrimInFlight, size > 0, size + UInt64(line.count) > maxActiveFileBytes {
            try rotate()
            fh = try handleForWriting()
        }
        try fh.write(contentsOf: line)
    }

    /// Loads the last `limit` items. Order in the returned array is
    /// oldest-first. Missing files return empty.
    public func loadRecent(limit: Int) throws -> [WorkstreamItem] {
        try loadPage(endingBefore: nil, limit: limit).items
    }

    /// Legacy entry point for a bare byte offset into the active file.
    public func loadPage(endingBefore endOffset: UInt64, limit: Int) throws -> Page {
        try loadPage(endingBefore: Cursor(file: nil, offset: endOffset), limit: limit)
    }

    /// Loads up to `limit` items ending before `cursor`, newest page when
    /// `cursor` is nil. Order in the returned array is oldest-first. A page
    /// that reaches the start of the active file continues into the
    /// previous generation. `startCursor` names a file by identity, so it
    /// stays valid while rows are appended and across a rotation. A cursor
    /// whose file was dropped by a later rotation returns an empty page.
    public func loadPage(
        endingBefore cursor: Cursor? = nil,
        limit: Int
    ) throws -> Page {
        let empty = Page(items: [], hasMoreBefore: false, startCursor: nil)
        guard limit > 0 else { return empty }
        startLegacyTrimIfNeeded()
        let cursor = cursor.map(reanchored)

        let activeIdentity = Self.identity(atPath: fileURL.path)
        let previousIdentity = Self.identity(atPath: previousFileURL.path)
        var lines: [LogLine] = []
        var readActive = true
        var activeEnd: UInt64?
        if let cursor {
            if cursor.file == nil || cursor.file == activeIdentity {
                activeEnd = cursor.offset
            } else if cursor.file == previousIdentity {
                readActive = false
                lines = try Self.readLines(
                    at: previousFileURL,
                    endingBefore: cursor.offset,
                    limit: limit
                )
            } else {
                return empty
            }
        }
        if readActive {
            lines = try Self.readLines(at: fileURL, endingBefore: activeEnd, limit: limit)
            if lines.count < limit, (lines.first?.offset ?? 0) == 0 {
                let older = try Self.readLines(
                    at: previousFileURL,
                    endingBefore: nil,
                    limit: limit - lines.count
                )
                lines.insert(contentsOf: older, at: 0)
            }
        }

        var out: [WorkstreamItem] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            if let item = try? decoder.decode(WorkstreamItem.self, from: line.data) {
                out.append(item)
            }
            // Malformed lines are dropped silently; the audit log is
            // append-only and we don't want a corrupt row to block startup.
        }
        guard let first = lines.first else { return empty }
        let hasMoreBefore: Bool
        if first.offset > 0 {
            hasMoreBefore = true
        } else if first.file == previousIdentity {
            hasMoreBefore = false
        } else {
            hasMoreBefore = Self.fileSize(atPath: previousFileURL.path) > 0
        }
        return Page(
            items: out,
            hasMoreBefore: hasMoreBefore,
            startCursor: Cursor(file: first.file, offset: first.offset)
        )
    }

    /// Deletes both generations. Used by `cmux feed clear`.
    public func clear() throws {
        closeWriteHandle()
        for url in [fileURL, previousFileURL] {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain,
                   nsError.code == NSFileNoSuchFileError {
                    continue
                }
                throw error
            }
        }
    }

    /// Waits for the one-time legacy trim, if one was started.
    func waitForLegacyTrim() async {
        await legacyTrimTask?.value
    }

    /// Runs `gate` after the trim copy and before its swap. Tests use it
    /// to append while the copy snapshot is outstanding.
    func setLegacyTrimFinalizeGateForTesting(_ gate: @escaping @Sendable () async -> Void) {
        legacyTrimFinalizeGate = gate
    }

    // MARK: - Private

    private struct LogLine {
        let data: Data
        let offset: UInt64
        let file: FileIdentity
    }

    private struct TrimSnapshot: Sendable {
        let fileURL: URL
        let file: FileIdentity
        let size: UInt64
        let maxBytes: UInt64
    }

    private struct StagedTrim: Sendable {
        let snapshot: TrimSnapshot
        let tempURL: URL
        let keepFrom: UInt64
    }

    private func reanchored(_ cursor: Cursor) -> Cursor {
        guard let file = cursor.file, let anchor = reanchors[file] else { return cursor }
        let offset = cursor.offset > anchor.droppedBytes ? cursor.offset - anchor.droppedBytes : 0
        return Cursor(file: anchor.file, offset: offset)
    }

    /// Snapshots an active file that grew past the cap before rotation
    /// existed and starts its trim off this actor. Runs at most once per
    /// instance; later growth is handled by rotation.
    private func startLegacyTrimIfNeeded() {
        guard !hasCheckedOversizedFile else { return }
        hasCheckedOversizedFile = true
        var info = stat()
        guard stat(fileURL.path, &info) == 0, info.st_size > 0 else { return }
        let size = UInt64(info.st_size)
        guard size > maxActiveFileBytes else { return }
        let snapshot = TrimSnapshot(
            fileURL: fileURL,
            file: Self.identity(from: info),
            size: size,
            maxBytes: maxActiveFileBytes
        )
        legacyTrimInFlight = true
        let gate = legacyTrimFinalizeGate
        legacyTrimTask = Task.detached(priority: .utility) { [self] in
            let staged: StagedTrim
            do {
                staged = try Self.stageTrim(snapshot)
            } catch {
                await self.abandonLegacyTrim(tempURL: nil)
                return
            }
            await gate?()
            await self.finishLegacyTrim(staged)
        }
    }

    /// Swaps the staged copy in. Runs on the actor, so no in-process append
    /// interleaves: bytes appended after the snapshot are copied onto the
    /// staged file before the rename.
    private func finishLegacyTrim(_ staged: StagedTrim) {
        let snapshot = staged.snapshot
        guard Self.identity(atPath: fileURL.path) == snapshot.file else {
            // Cleared or replaced during the copy; nothing to swap.
            abandonLegacyTrim(tempURL: staged.tempURL)
            return
        }
        do {
            let currentSize = Self.fileSize(atPath: fileURL.path)
            if currentSize > snapshot.size {
                try Self.appendRange(
                    of: fileURL,
                    from: snapshot.size,
                    to: currentSize,
                    onto: staged.tempURL
                )
            }
            guard rename(staged.tempURL.path, fileURL.path) == 0 else {
                throw POSIXError(Self.currentErrno())
            }
        } catch {
            // A failed trim leaves the file as it was; the next launch retries.
            abandonLegacyTrim(tempURL: staged.tempURL)
            return
        }
        closeWriteHandle()
        if let trimmed = Self.identity(atPath: fileURL.path) {
            reanchors[snapshot.file] = (file: trimmed, droppedBytes: staged.keepFrom)
        }
        legacyTrimInFlight = false
    }

    private func abandonLegacyTrim(tempURL: URL?) {
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
        legacyTrimInFlight = false
    }

    private func handleForWriting() throws -> FileHandle {
        if let handle, let handleIdentity,
           Self.identity(atPath: fileURL.path) == handleIdentity {
            return handle
        }
        closeWriteHandle()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(Self.currentErrno()) }
        let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let identity = Self.identity(of: fd) else {
            try? fh.close()
            throw POSIXError(Self.currentErrno())
        }
        handle = fh
        handleIdentity = identity
        return fh
    }

    private func closeWriteHandle() {
        try? handle?.close()
        handle = nil
        handleIdentity = nil
    }

    /// Moves the active file over the previous generation. `rename(2)`
    /// replaces the old generation atomically and keeps the moved file's
    /// identity, so outstanding cursors follow it.
    private func rotate() throws {
        closeWriteHandle()
        guard rename(fileURL.path, previousFileURL.path) == 0 else {
            let code = Self.currentErrno()
            // Another process already moved or removed it.
            if code == .ENOENT { return }
            throw POSIXError(code)
        }
    }

    // MARK: - File helpers

    private static func currentErrno() -> POSIXErrorCode {
        POSIXErrorCode(rawValue: errno) ?? .EIO
    }

    private static func identity(from info: stat) -> FileIdentity {
        #if canImport(Darwin)
        let birthSeconds = Int64(info.st_birthtimespec.tv_sec)
        let birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
        #else
        let birthSeconds: Int64 = 0
        let birthNanoseconds: Int64 = 0
        #endif
        return FileIdentity(
            device: UInt64(UInt32(bitPattern: Int32(truncatingIfNeeded: info.st_dev))),
            inode: UInt64(info.st_ino),
            birthSeconds: birthSeconds,
            birthNanoseconds: birthNanoseconds
        )
    }

    private static func identity(atPath path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return identity(from: info)
    }

    private static func identity(of fd: Int32) -> FileIdentity? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return identity(from: info)
    }

    private static func fileSize(atPath path: String) -> UInt64 {
        var info = stat()
        guard stat(path, &info) == 0, info.st_size > 0 else { return 0 }
        return UInt64(info.st_size)
    }

    private static func size(of fh: FileHandle) throws -> UInt64 {
        var info = stat()
        guard fstat(fh.fileDescriptor, &info) == 0 else {
            throw POSIXError(currentErrno())
        }
        return UInt64(max(0, info.st_size))
    }

    /// Reads up to `limit` complete lines ending before `endOffset`, newest
    /// last, paging backward in 64 KB chunks. Missing file returns empty.
    private static func readLines(
        at url: URL,
        endingBefore endOffset: UInt64?,
        limit: Int
    ) throws -> [LogLine] {
        guard limit > 0 else { return [] }
        let fh: FileHandle
        do {
            fh = try FileHandle(forReadingFrom: url)
        } catch {
            return []
        }
        defer { try? fh.close() }
        guard let file = identity(of: fh.fileDescriptor) else { return [] }
        let fileSize = try fh.seekToEnd()
        let pageEnd = min(endOffset ?? fileSize, fileSize)
        guard fileSize > 0, pageEnd > 0 else { return [] }

        let chunkSize = 64 * 1024
        var offset = pageEnd
        var tail = Data()
        var lineRanges: [(range: Range<Int>, startOffset: UInt64)] = []
        while offset > 0 {
            let readSize = min(chunkSize, Int(offset))
            offset -= UInt64(readSize)
            try fh.seek(toOffset: offset)
            guard let chunk = try fh.read(upToCount: readSize), !chunk.isEmpty else {
                break
            }
            tail.insert(contentsOf: chunk, at: 0)
            lineRanges = Self.lineRanges(in: tail, baseOffset: offset)
            if lineRanges.count > limit {
                break
            }
        }
        if lineRanges.isEmpty {
            lineRanges = Self.lineRanges(in: tail, baseOffset: offset)
        }
        return lineRanges.suffix(limit).map { lineRange in
            LogLine(
                data: tail.subdata(in: lineRange.range),
                offset: lineRange.startOffset,
                file: file
            )
        }
    }

    /// Copies the snapshot's bytes from the first line start at or after
    /// `size - maxBytes` into a sibling temp file. Runs off the actor.
    private static func stageTrim(_ snapshot: TrimSnapshot) throws -> StagedTrim {
        let reader = try FileHandle(forReadingFrom: snapshot.fileURL)
        defer { try? reader.close() }
        guard identity(of: reader.fileDescriptor) == snapshot.file else {
            throw POSIXError(.ESTALE)
        }
        let keepFrom = try firstLineStart(
            atOrAfter: snapshot.size - snapshot.maxBytes,
            in: reader,
            fileSize: snapshot.size
        )
        let tempURL = snapshot.fileURL.deletingLastPathComponent().appendingPathComponent(
            ".\(snapshot.fileURL.lastPathComponent).trim-\(UUID().uuidString)",
            isDirectory: false
        )
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(currentErrno()) }
        let writer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try copyBytes(from: reader, start: keepFrom, end: snapshot.size, to: writer)
            try writer.close()
        } catch {
            try? writer.close()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        return StagedTrim(snapshot: snapshot, tempURL: tempURL, keepFrom: keepFrom)
    }

    private static func appendRange(
        of url: URL,
        from start: UInt64,
        to end: UInt64,
        onto destination: URL
    ) throws {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let fd = open(destination.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(currentErrno()) }
        let writer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? writer.close() }
        try copyBytes(from: reader, start: start, end: end, to: writer)
    }

    private static func copyBytes(
        from reader: FileHandle,
        start: UInt64,
        end: UInt64,
        to writer: FileHandle
    ) throws {
        try reader.seek(toOffset: start)
        var remaining = end > start ? end - start : 0
        let chunkSize: UInt64 = 1024 * 1024
        while remaining > 0 {
            let count = Int(min(chunkSize, remaining))
            guard let chunk = try reader.read(upToCount: count), !chunk.isEmpty else {
                break
            }
            try writer.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
    }

    /// Offset of the first byte after a newline at or after `start - 1`,
    /// or `fileSize` when no newline follows.
    private static func firstLineStart(
        atOrAfter start: UInt64,
        in fh: FileHandle,
        fileSize: UInt64
    ) throws -> UInt64 {
        guard start > 0 else { return 0 }
        var position = start - 1
        try fh.seek(toOffset: position)
        while position < fileSize {
            guard let chunk = try fh.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                break
            }
            if let newline = chunk.firstIndex(of: 0x0A) {
                return position + UInt64(chunk.distance(from: chunk.startIndex, to: newline)) + 1
            }
            position += UInt64(chunk.count)
        }
        return fileSize
    }

    private static func lineRanges(
        in data: Data,
        baseOffset: UInt64
    ) -> [(range: Range<Int>, startOffset: UInt64)] {
        var ranges: [(range: Range<Int>, startOffset: UInt64)] = []
        ranges.reserveCapacity(128)
        var lineStart = 0
        for (idx, byte) in data.enumerated() {
            guard byte == 0x0A else { continue }
            if lineStart < idx {
                ranges.append(
                    (
                        range: lineStart..<idx,
                        startOffset: baseOffset + UInt64(lineStart)
                    )
                )
            }
            lineStart = idx + 1
        }
        if lineStart < data.count {
            ranges.append(
                (
                    range: lineStart..<data.count,
                    startOffset: baseOffset + UInt64(lineStart)
                )
            )
        }
        return ranges
    }
}


private extension WorkstreamItem {
    func redactedForPersistence() -> WorkstreamItem {
        var copy = self
        copy.payload = payload.redactedForPersistence()
        return copy
    }
}

private extension WorkstreamPayload {
    func redactedForPersistence() -> WorkstreamPayload {
        switch self {
        case .permissionRequest(let requestId, let toolName, let toolInputJSON, let pattern):
            return .permissionRequest(
                requestId: requestId,
                toolName: toolName,
                toolInputJSON: WorkstreamPersistenceRedactor.redactToolInputJSON(toolInputJSON),
                pattern: pattern
            )
        case .toolUse(let toolName, let toolInputJSON):
            return .toolUse(
                toolName: toolName,
                toolInputJSON: WorkstreamPersistenceRedactor.redactToolInputJSON(toolInputJSON)
            )
        case .toolResult(let toolName, let resultJSON, let isError):
            return .toolResult(
                toolName: toolName,
                resultJSON: WorkstreamPersistenceRedactor.redactToolInputJSON(resultJSON),
                isError: isError
            )
        default:
            return self
        }
    }
}

private enum WorkstreamPersistenceRedactor {
    private static let sensitiveFragments = [
        "token",
        "secret",
        "password",
        "passwd",
        "api_key",
        "apikey",
        "access_key",
        "private_key",
        "authorization",
        "cookie",
        "credential",
        "env",
    ]

    static func redactToolInputJSON(_ input: String) -> String {
        guard let data = input.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
              )
        else {
            return redactString(input)
        }

        let redacted = redactJSONValue(value, key: nil)
        guard JSONSerialization.isValidJSONObject(redacted) || redacted is String
        else { return redactString(input) }
        guard let out = try? JSONSerialization.data(
            withJSONObject: redacted,
            options: [.fragmentsAllowed, .sortedKeys]
        ),
              let string = String(data: out, encoding: .utf8)
        else { return redactString(input) }
        return string
    }

    private static func redactJSONValue(_ value: Any, key: String?) -> Any {
        if let key, isSensitiveKey(key) {
            return "<redacted>"
        }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = redactJSONValue(v, key: k)
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map { redactJSONValue($0, key: nil) }
        }
        if let string = value as? String {
            return redactString(string)
        }
        return value
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        return sensitiveFragments.contains { normalized.contains($0) }
    }

    private static func redactString(_ string: String) -> String {
        var out = string
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if !homePath.isEmpty {
            out = out.replacingOccurrences(of: homePath, with: "~")
        }
        return redactEnvironmentAssignments(in: out)
    }

    private static func redactEnvironmentAssignments(in string: String) -> String {
        let pattern = #"(?i)\b([A-Z_][A-Z0-9_]*(TOKEN|SECRET|PASSWORD|PASSWD|API[_-]?KEY|ACCESS[_-]?KEY|PRIVATE[_-]?KEY|AUTHORIZATION|COOKIE|CREDENTIAL)[A-Z0-9_]*)=("[^"]*"|'[^']*'|[^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return string
        }
        var out = string
        let range = NSRange(out.startIndex..<out.endIndex, in: out)
        for match in regex.matches(in: out, range: range).reversed() {
            guard match.numberOfRanges >= 4,
                  let valueRange = Range(match.range(at: 3), in: out)
            else { continue }
            out.replaceSubrange(valueRange, with: "<redacted>")
        }
        return out
    }
}
