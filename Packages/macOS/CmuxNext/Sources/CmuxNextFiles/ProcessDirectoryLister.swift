public import Foundation
import CmuxNextCompat

/// Lists folders in a child process that speaks cmux-tui's `__files-lister` protocol
/// (cmux-tui `files_lister.rs`): one JSON request per line on its stdin, one reply per line on its
/// stdout.
///
/// A DEV build runs that child under its "cmux Files (dev)" helper (``FilesHost``), so macOS
/// charges the Files pane's reads of Desktop, Documents and Downloads to the helper, which every
/// DEV build shares, instead of to each tag's app: one Files and Folders answer covers every tag,
/// as it does for the terminals (docs/cmux-files-host.md, "The Files pane"). Shipped builds never
/// start one (``forThisBuild()`` answers nil to every request without a ``FilesHost``).
///
/// The child starts at the first request and serves until this app ends (its stdin closes). A
/// child that fails to start, exits, or answers a line it did not understand makes that request
/// return nil, and the caller reads in its own process as before; after
/// ``maximumConsecutiveFailures`` failures without an answer in between it stops trying. Reads of
/// the reply happen on Foundation's pipe queue, writes on the request feed's queue: nothing here
/// blocks the caller's thread.
public final class ProcessDirectoryLister: Sendable {
    /// One child's answer.
    enum Reply: Sendable, Equatable {
        /// A folder's children.
        case entries([FileEntry])
        /// One item, or nil when it is gone.
        case entry(FileEntry?)
        /// The folder could not be read (`errno`).
        case unreadable(Int32)
    }

    /// Failures in a row (no answer in between) after which every request reads in process.
    static let maximumConsecutiveFailures = 3
    /// The longest reply line read: a listing of a few hundred thousand items.
    static let maximumReplyBytes = 256 << 20

    private struct Pending {
        var parent: URL
        var continuation: CheckedContinuation<Reply?, Never>
    }

    private struct State {
        var process: Process?
        var feed: PipeFeed?
        var nextID = 1
        var pending: [Int: Pending] = [:]
        var buffer = Data()
        var failures = 0
    }

    private let resolve: @Sendable () -> [String]?
    private let arguments = Mutex<[String]??>(nil)
    private let state = Mutex(State())

    /// - Parameter arguments: the child's argv; the first is the executable.
    public convenience init(arguments: [String]) {
        self.init(resolving: { arguments })
    }

    /// - Parameter resolving: the child's argv, or nil to read in process; asked once, at the first
    ///   request, off the caller's thread (it may stat).
    public init(resolving: @escaping @Sendable () -> [String]?) {
        resolve = resolving
    }

    /// This build's lister. In a DEV build that embeds the helper it runs `bin/cmux-tui
    /// __files-lister` under it; everywhere else (a shipped build, no helper,
    /// `CMUX_NEXT_FILES_HOST=0`, no bundled cmux-tui) every request answers nil and the caller reads
    /// in process. Making one touches no disk: the helper is looked up at the first request.
    public static func forThisBuild() -> ProcessDirectoryLister {
        ProcessDirectoryLister(resolving: {
            guard let host = FilesHost.current(),
                  let tui = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux-tui"),
                  FileManager.checked.isExecutableFile(atPath: tui.path)
            else { return nil }
            return host.arguments(running: tui.path) + ["__files-lister"]
        })
    }

    /// True when this build has a child to read through (it looks it up on first use: may stat).
    public var readsOutOfProcess: Bool { resolvedArguments() != nil }

    /// The children of `folder`, or nil when the child could not answer (read in process).
    /// - Throws: ``FileBrowserError/unreadable(_:_:)`` when the child could not read the folder,
    ///   `CancellationError` when the caller was cancelled.
    func list(_ folder: URL) async throws -> [FileEntry]? {
        switch try await request(op: "list", path: folder.path, parent: folder) {
        case .entries(let entries): return entries
        case .unreadable(let code): throw FileBrowserError.unreadable(folder, code)
        case .entry, nil: return nil
        }
    }

    /// The entry of `url`: `.some(nil)` when it is gone, nil when the child could not answer.
    func entry(at url: URL) async throws -> FileEntry?? {
        switch try await request(op: "entry", path: url.path, parent: url.deletingLastPathComponent()) {
        case .entry(let entry): return .some(entry)
        case .entries, .unreadable, nil: return nil
        }
    }

    deinit {
        let (feed, pending) = state.withLock { state in
            defer { state.pending.removeAll() }
            return (state.feed, state.pending.values.map(\.continuation))
        }
        feed?.close()
        for continuation in pending { continuation.resume(returning: nil) }
    }

    // MARK: - Requests

    private func request(op: String, path: String, parent: URL) async throws -> Reply? {
        let id = RequestID()
        let reply = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Reply?, Never>) in
                let started = state.withLock { state -> (PipeFeed, Int)? in
                    guard state.failures < Self.maximumConsecutiveFailures, let feed = start(&state) else { return nil }
                    let next = state.nextID
                    state.nextID += 1
                    state.pending[next] = Pending(parent: parent, continuation: continuation)
                    return (feed, next)
                }
                guard let (feed, next) = started else { return continuation.resume(returning: nil) }
                id.value.withLock { $0 = next }
                let line = (try? JSONSerialization.data(withJSONObject: ["id": next, "op": op, "path": path])) ?? Data()
                feed.write(line + Data([0x0A]))
                if Task.isCancelled { cancel(id.value.withLock { $0 }) }
            }
        } onCancel: {
            cancel(id.value.withLock { $0 })
        }
        try Task.checkCancellation()
        return reply
    }

    private func cancel(_ id: Int?) {
        guard let id else { return }
        let pending = state.withLock { $0.pending.removeValue(forKey: id) }
        pending?.continuation.resume(returning: nil)
    }

    /// The running child's request feed, starting the child when there is none.
    private func start(_ state: inout State) -> PipeFeed? {
        if let feed = state.feed { return feed }
        guard let argv = resolvedArguments(), let executable = argv.first else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let feed = PipeFeed(input.fileHandleForWriting)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            switch handle.readReady() {
            case .bytes(let data): self?.received(data)
            case .retry: return
            case .end: handle.readabilityHandler = nil
            }
        }
        process.terminationHandler = { [weak self] finished in self?.ended(finished) }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            feed.close()
            state.failures += 1
            return nil
        }
        state.process = process
        state.feed = feed
        return feed
    }

    private func resolvedArguments() -> [String]? {
        arguments.withLock { cached in
            if let cached { return cached }
            let resolved = resolve()
            cached = .some(resolved)
            return resolved
        }
    }

    /// The child exited: every request it had not answered reads in process.
    private func ended(_ process: Process) {
        let (feed, pending) = state.withLock { state -> (PipeFeed?, [CheckedContinuation<Reply?, Never>]) in
            guard state.process === process else { return (nil, []) }
            let feed = state.feed
            state.process = nil
            state.feed = nil
            state.buffer.removeAll()
            if !state.pending.isEmpty { state.failures += 1 }
            defer { state.pending.removeAll() }
            return (feed, state.pending.values.map(\.continuation))
        }
        feed?.close()
        for continuation in pending { continuation.resume(returning: nil) }
    }

    private func received(_ data: Data) {
        let lines = state.withLock { state -> [Data] in
            state.buffer.append(data)
            var lines: [Data] = []
            while let newline = state.buffer.firstIndex(of: 0x0A) {
                lines.append(Data(state.buffer[state.buffer.startIndex..<newline]))
                state.buffer.removeSubrange(state.buffer.startIndex...newline)
            }
            if state.buffer.count > Self.maximumReplyBytes { state.buffer.removeAll() }
            return lines
        }
        for line in lines { answer(line) }
    }

    private func answer(_ line: Data) {
        guard let wire = try? JSONDecoder().decode(WireReply.self, from: line), let id = wire.id else { return }
        let pending = state.withLock { state -> Pending? in
            guard let pending = state.pending.removeValue(forKey: id) else { return nil }
            if wire.error == nil { state.failures = 0 } else { state.failures += 1 }
            return pending
        }
        guard let pending else { return }
        pending.continuation.resume(returning: wire.reply(in: pending.parent))
    }
}

/// The id a request was sent with, for its cancel handler.
private final class RequestID: Sendable {
    let value = Mutex<Int?>(nil)
}

/// One reply line of `__files-lister` (files_lister.rs).
private struct WireReply: Decodable {
    var id: Int?
    var entries: [WireEntry]?
    var entry: WireEntry?
    var hasEntry: Bool
    var errno: Int32?
    var error: String?

    enum CodingKeys: String, CodingKey { case id, entries, entry, errno, error }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(Int.self, forKey: .id)
        entries = try container.decodeIfPresent([WireEntry].self, forKey: .entries)
        hasEntry = container.contains(.entry)
        entry = try container.decodeIfPresent(WireEntry.self, forKey: .entry)
        errno = try container.decodeIfPresent(Int32.self, forKey: .errno)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    func reply(in parent: URL) -> ProcessDirectoryLister.Reply? {
        if error != nil { return nil }
        if let errno { return .unreadable(errno) }
        if let entries {
            var packages: [String: Bool] = [:]
            return .entries(entries.map { $0.fileEntry(in: parent, packages: &packages) })
        }
        if hasEntry {
            var packages: [String: Bool] = [:]
            return .entry(entry?.fileEntry(in: parent, packages: &packages))
        }
        return nil
    }
}

/// `{"n", "k", "s", "m", "c", "h"}` (files_lister.rs `encode`).
private struct WireEntry: Decodable {
    var n: String
    var k: String
    var s: Int64
    var m: Double
    var c: Double
    var h: Bool

    func fileEntry(in parent: URL, packages: inout [String: Bool]) -> FileEntry {
        let kind: FileKind
        switch k {
        case "dir":
            let ext = (n as NSString).pathExtension
            if ext.isEmpty {
                kind = .folder
            } else if let cached = packages[ext] {
                kind = cached ? .package : .folder
            } else {
                let package = DirectoryLister.isPackage(n)
                packages[ext] = package
                kind = package ? .package : .folder
            }
        case "file": kind = .file
        case "link": kind = .symlink
        default: kind = .other
        }
        return FileEntry(name: n, in: parent, kind: kind, size: kind == .file ? s : 0,
                         modified: Date(timeIntervalSince1970: m), created: Date(timeIntervalSince1970: c), isHidden: h)
    }
}
