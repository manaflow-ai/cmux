#if canImport(CCmuxFilesListerFFI)
import CCmuxFilesListerFFI
#endif
public import Foundation
import CmuxNextCompat

/// Lists folders in a child process that speaks cmux-tui's `__files-lister` protocol
/// (cmux-tui `files_lister.rs`) through the app FFI's client (cmux-app-ffi `src/files_lister.rs`,
/// module `CCmuxFilesListerFFI`), which starts the child, matches replies to requests and stops
/// trying after repeated failures.
///
/// A DEV build runs that child under its "cmux Files (dev)" helper (``FilesHost``), so macOS
/// charges the Files pane's reads of Desktop, Documents and Downloads to the helper, which every
/// DEV build shares, instead of to each tag's app: one Files and Folders answer covers every tag,
/// as it does for the terminals (docs/cmux-files-host.md, "The Files pane"). Shipped builds never
/// start one (``forThisBuild()`` answers nil to every request without a ``FilesHost``).
///
/// The child starts at the first request and serves until this lister ends. A request the child
/// cannot answer returns nil, and the caller reads in its own process as before. Nothing here
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

    private let resolve: @Sendable () -> [String]?
    private let arguments = Mutex<[String]??>(nil)
    private let client = Mutex<FilesListerClient??>(nil)

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

    private func request(op: String, path: String, parent: URL) async throws -> Reply? {
        guard let client = resolvedClient() else { return nil }
        let id = RequestID()
        let line = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                let sent = client.send(op: op, path: path, continuation)
                id.value.withLock { $0 = sent }
                if Task.isCancelled { client.cancel(sent) }
            }
        } onCancel: {
            client.cancel(id.value.withLock { $0 })
        }
        try Task.checkCancellation()
        guard let line, let wire = try? JSONDecoder().decode(WireReply.self, from: line) else { return nil }
        return wire.reply(in: parent)
    }

    private func resolvedClient() -> FilesListerClient? {
        client.withLock { cached in
            if let cached { return cached }
            let made = resolvedArguments().flatMap(FilesListerClient.init(arguments:))
            cached = .some(made)
            return made
        }
    }

    private func resolvedArguments() -> [String]? {
        arguments.withLock { cached in
            if let cached { return cached }
            let resolved = resolve()
            cached = .some(resolved)
            return resolved
        }
    }
}

/// The id a request was sent with, for its cancel handler.
private final class RequestID: Sendable {
    let value = Mutex<UInt64?>(nil)
}

/// The app FFI's lister: freeing it answers every pending request with nil and ends the child.
private final class FilesListerClient: Sendable {
    #if canImport(CCmuxFilesListerFFI)
    /// The handle's address: its calls are thread-safe (src/files_lister.rs); freed once, in deinit.
    private let address: UInt
    private var handle: OpaquePointer? { OpaquePointer(bitPattern: address) }

    init?(arguments: [String]) {
        let strings = arguments.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        let pointers = strings.map { UnsafePointer($0) }
        guard let handle = pointers.withUnsafeBufferPointer({ cmux_files_lister_new($0.baseAddress, $0.count) })
        else { return nil }
        address = UInt(bitPattern: handle)
    }

    deinit { cmux_files_lister_free(handle) }

    /// Sends one request: its id, or nil (and `continuation` already resumed with nil) when refused.
    func send(op: String, path: String, _ continuation: CheckedContinuation<Data?, Never>) -> UInt64? {
        let context = Unmanaged.passRetained(ReplySlot(continuation)).toOpaque()
        let id = op.withCString { op in
            path.withCString { path in
                // The one callback: the reply line, or none (read in process).
                cmux_files_lister_request(handle, op, path, { context, bytes, count in
                    guard let context else { return }
                    let slot = Unmanaged<ReplySlot>.fromOpaque(context).takeRetainedValue()
                    slot.continuation.resume(returning: bytes.map { Data(bytes: $0, count: count) })
                }, context)
            }
        }
        guard id != 0 else {
            Unmanaged<ReplySlot>.fromOpaque(context).release()
            continuation.resume(returning: nil)
            return nil
        }
        return id
    }

    func cancel(_ id: UInt64?) {
        guard let id else { return }
        _ = cmux_files_lister_cancel(handle, id)
    }
    #else
    init?(arguments: [String]) { nil }
    func send(op: String, path: String, _ continuation: CheckedContinuation<Data?, Never>) -> UInt64? {
        continuation.resume(returning: nil)
        return nil
    }
    func cancel(_ id: UInt64?) {}
    #endif
}

#if canImport(CCmuxFilesListerFFI)
/// One request's continuation, handed to the FFI and resumed by its one callback.
private final class ReplySlot {
    let continuation: CheckedContinuation<Data?, Never>
    init(_ continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }
}
#endif

/// One reply line of `__files-lister` (files_lister.rs) the FFI passed on: never an `error` one.
private struct WireReply: Decodable {
    var entries: [WireEntry]?
    var entry: WireEntry?
    var hasEntry: Bool
    var errno: Int32?

    enum CodingKeys: String, CodingKey { case entries, entry, errno }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([WireEntry].self, forKey: .entries)
        hasEntry = container.contains(.entry)
        entry = try container.decodeIfPresent(WireEntry.self, forKey: .entry)
        errno = try container.decodeIfPresent(Int32.self, forKey: .errno)
    }

    func reply(in parent: URL) -> ProcessDirectoryLister.Reply? {
        if let errno { return .unreadable(errno) }
        var packages: [String: Bool] = [:]
        if let entries { return .entries(entries.map { $0.fileEntry(in: parent, packages: &packages) }) }
        if hasEntry { return .entry(entry?.fileEntry(in: parent, packages: &packages)) }
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
