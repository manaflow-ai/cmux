import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation

/// A machine's `fs-v1` ops, on its daemon's read link; tests pass a fake.
protocol RemoteFileClient: AnyObject {
    func stat(_ path: String) async throws -> FileSystemStatRequest.Response
    func read(_ path: String, maxBytes: Int) async throws -> FileSystemReadRequest.Response
    func replace(_ path: String, text: String, expected: String) async throws -> FileSystemReplaceRequest.Response
}

extension AgentPaneGitLink: RemoteFileClient {
    /// A stat is one syscall on the VM: the deadline covers the link, not the work.
    static let fileStatTimeout: Duration = .seconds(10)
    /// A read or write moves up to 16 MiB over the link.
    static let fileTransferTimeout: Duration = .seconds(30)

    func stat(_ path: String) async throws -> FileSystemStatRequest.Response {
        try await request(FileSystemStatRequest(path: path), timeout: Self.fileStatTimeout)
    }

    func read(_ path: String, maxBytes: Int) async throws -> FileSystemReadRequest.Response {
        try await request(FileSystemReadRequest(path: path, maxBytes: maxBytes), timeout: Self.fileTransferTimeout)
    }

    func replace(_ path: String, text: String, expected: String) async throws -> FileSystemReplaceRequest.Response {
        try await request(FileSystemReplaceRequest(path: path, text: text, expected: expected), timeout: Self.fileTransferTimeout)
    }
}

/// A file page's file on another machine (#25581): read, saved and watched through that machine's
/// daemon (`fs-v1`, served by Cloud VMs over their home folder), so a tab in a Cloud workspace
/// shows the VM's file. A save replaces the file only at the revision the page's text was read
/// at; the watch polls the file's revision (the daemon has no file events).
final class RemoteFilePageFiles: FilePageFiles {
    /// The largest file a page opens from a machine: the daemon's single-read cap.
    static let maximumBytes = FileSystemReadRequest.maximumBytes
    /// Reads of a file that changes during each one before its revision counts as unknown.
    static let readAttempts = 3

    let client: any RemoteFileClient
    /// The machine's name, for the page's messages.
    let machine: String

    init(client: any RemoteFileClient, machine: String) {
        self.client = client
        self.machine = machine
    }

    var isLocal: Bool { false }

    /// No symlink of this Mac is followed: the path is the machine's.
    func canonical(_ url: URL) -> URL { url.standardizedFileURL }

    func read(_ url: URL, inWorkspace: Bool) async throws(FileOpenFailure) -> FileSnapshot {
        try await load(url, inWorkspace: inWorkspace).snapshot
    }

    /// The file and the revision its bytes were read at, or nil when that is unknown: the path is
    /// a symlink (a stat answers the link's own revision, a write checks its target's), or the
    /// file kept changing while it was read. A save then asks the target's revision first.
    func load(_ url: URL, inWorkspace: Bool) async throws(FileOpenFailure) -> (snapshot: FileSnapshot, revision: String?) {
        let path = canonical(url).path
        for attempt in 1...Self.readAttempts {
            let before = try await stat(path)
            let reply: FileSystemReadRequest.Response
            do {
                reply = try await client.read(path, maxBytes: Self.maximumBytes)
            } catch {
                throw openFailure(error)
            }
            guard !reply.truncated else { throw .tooLarge }
            let after = try await stat(path)
            let settled = after.revision == before.revision
            if !settled, attempt < Self.readAttempts { continue }
            guard let snapshot = await Self.snapshot(URL(fileURLWithPath: path), reply: reply, inWorkspace: inWorkspace) else {
                throw .notFile
            }
            return (snapshot, settled && after.kind == "file" ? after.revision : nil)
        }
        throw .notFile
    }

    private func stat(_ path: String) async throws(FileOpenFailure) -> FileSystemStatRequest.Response {
        let stat: FileSystemStatRequest.Response
        do {
            stat = try await client.stat(path)
        } catch {
            throw openFailure(error)
        }
        // A symlink is followed by the read itself (inside the machine's roots).
        guard stat.kind == "file" || stat.kind == "symlink" else { throw .notFile }
        if stat.kind == "file", let size = stat.size, size > UInt64(Self.maximumBytes) { throw .tooLarge }
        return stat
    }

    /// The page's snapshot of the bytes `reply` carries (nil when its base64 does not decode), with
    /// the read-only reasons of ``FileDocument/read`` that the bytes decide. Whether the machine
    /// lets this user write is known only when a save tries. Up to 16 MiB to decode and hash: off
    /// the main actor.
    @concurrent nonisolated static func snapshot(_ url: URL, reply: FileSystemReadRequest.Response, inWorkspace: Bool) async -> FileSnapshot? {
        guard let bytes = reply.bytes else { return nil }
        let (text, exact) = FileDocument.decode(bytes)
        let reason: FileReadOnlyReason? = if FileDocument.isBinary(bytes) {
            .binary
        } else if !exact {
            .encoding
        } else if !inWorkspace {
            .outside
        } else {
            nil
        }
        return FileSnapshot(url: url, text: text, hash: FileDocument.hash(bytes), size: bytes.count, readOnlyReason: reason)
    }

    func save(_ text: String, to url: URL, baseHash: String?, inWorkspace: Bool) async throws(FileSaveFailure) -> FileSaveResult {
        let current: (snapshot: FileSnapshot, revision: String?)
        do {
            current = try await load(url, inWorkspace: inWorkspace)
        } catch .notFound {
            // A page never creates a file on another machine; its file went away.
            throw baseHash == nil ? .readOnly : .deleted
        } catch .unavailable(let reason) {
            throw .failed(reason)
        } catch {
            throw .readOnly
        }
        if current.snapshot.readOnlyReason != nil { throw .readOnly }
        guard current.snapshot.hash == baseHash else {
            throw .conflict(hash: current.snapshot.hash, text: current.snapshot.text)
        }
        let newHash = await Self.hash(text)
        if current.snapshot.hash == newHash { return FileSaveResult(hash: newHash, written: false) }
        let path = current.snapshot.url.path
        let expected: String
        if let revision = current.revision {
            expected = revision
        } else {
            expected = try await targetRevision(path, url: url, baseHash: baseHash, inWorkspace: inWorkspace)
        }
        do {
            _ = try await client.replace(path, text: text, expected: expected)
        } catch {
            guard Self.code(of: error) == "fs.revision_mismatch" else { throw saveFailure(error) }
            throw await conflict(url, inWorkspace: inWorkspace)
        }
        return FileSaveResult(hash: newHash, written: true)
    }

    /// The revision a write checks, for a file whose read could not tell it (a symlink's target, a
    /// file that kept changing). A replace that cannot match (an empty revision, which no file
    /// has) writes nothing and answers the target's current revision; the file read after that
    /// must still be the page's base, so any write in between is a conflict, and any write after
    /// it fails the real replace.
    private func targetRevision(_ path: String, url: URL, baseHash: String?, inWorkspace: Bool) async throws(FileSaveFailure) -> String {
        var revision: String?
        do {
            _ = try await client.replace(path, text: "", expected: "")
        } catch {
            guard Self.code(of: error) == "fs.revision_mismatch" else { throw saveFailure(error) }
            revision = Self.currentRevision(of: error)
        }
        guard let revision else { throw .deleted }
        let now: FileSnapshot
        do {
            now = try await load(url, inWorkspace: inWorkspace).snapshot
        } catch {
            throw .deleted
        }
        guard now.hash == baseHash else { throw .conflict(hash: now.hash, text: now.text) }
        return revision
    }

    /// Written between the read and the write: what the file holds now.
    private func conflict(_ url: URL, inWorkspace: Bool) async -> FileSaveFailure {
        guard let now = try? await load(url, inWorkspace: inWorkspace) else { return .deleted }
        return .conflict(hash: now.snapshot.hash, text: now.snapshot.text)
    }

    /// The page's failure for an error of a write, in the page's words.
    private func saveFailure(_ error: any Error) -> FileSaveFailure {
        switch Self.code(of: error) {
        case "fs.permission_denied"?, "fs.read_only"?: return .readOnly
        default: break
        }
        switch openFailure(error) {
        case .unavailable(let reason): return .failed(reason)
        case .notFound: return .deleted
        case .tooLarge: return .failed(FilePageStrings.remoteTooLargeToSave(machine))
        case .notFile: return .readOnly
        }
    }

    @concurrent private nonisolated static func hash(_ text: String) async -> String {
        FileDocument.hash(Data(text.utf8))
    }

    func watch(_ url: URL, inWorkspace: @escaping () -> Bool, clock: any Clock<Duration>,
               onChange: @escaping (FileSnapshot?) -> Void, onUnavailable: @escaping (String?) -> Void) -> any FilePageWatching {
        RemoteFileChangeWatch(url: canonical(url), files: self, inWorkspace: inWorkspace, clock: clock,
                              onChange: onChange, onUnavailable: onUnavailable)
    }

    /// The page's failure for an error of an `fs.*` request.
    func openFailure(_ error: any Error) -> FileOpenFailure {
        switch error {
        case let failure as FileOpenFailure:
            return failure
        case DaemonError.missingCapabilities:
            return .unavailable(FilePageStrings.remoteNoFiles(machine))
        case DaemonError.notConnected, DaemonError.timedOut, DaemonError.connectionClosed, DaemonError.daemonShutdown:
            return .unavailable(FilePageStrings.remoteOffline(machine))
        default:
            switch Self.code(of: error) {
            case "fs.not_found"?: return .notFound
            case "fs.not_a_file"?, "fs.not_a_directory"?: return .notFile
            case "fs.too_large"?: return .tooLarge
            case "fs.permission_denied"?: return .unavailable(FilePageStrings.remoteDenied(machine))
            case "fs.unavailable"?: return .unavailable(FilePageStrings.remoteNoFiles(machine))
            default: return .unavailable(FilePageStrings.remoteOffline(machine))
            }
        }
    }

    /// The daemon's `error_code` of a refused command.
    static func code(of error: any Error) -> String? {
        if case DaemonError.command(_, _, let code, _, _) = error { return code }
        return nil
    }

    /// The revision an `fs.revision_mismatch` found (its `details.current`); nil when the file is gone.
    static func currentRevision(of error: any Error) -> String? {
        if case DaemonError.command(_, _, _, let details, _) = error { return details?["current"]?.stringValue }
        return nil
    }
}

/// Watches a file on another machine by its revision: every ``interval`` (on the injected clock)
/// it stats the file, reads it when the revision moved (every poll for a symlink, whose own
/// revision does not move when its target is written), and reports content whose hash differs
/// from ``knownHash`` (nil: deleted). A machine that stops answering is reported once through
/// `onUnavailable` with the reason, and once more (nil) when it answers again.
final class RemoteFileChangeWatch: FilePageWatching {
    static let interval: Duration = .seconds(2)

    let url: URL
    var knownHash: String?
    private let files: RemoteFilePageFiles
    private let inWorkspace: () -> Bool
    private let clock: any Clock<Duration>
    private let onChange: (FileSnapshot?) -> Void
    private let onUnavailable: (String?) -> Void
    private var poll: Task<Void, Never>?
    private var revision: String?
    private(set) var unavailable: String?

    init(url: URL, files: RemoteFilePageFiles, inWorkspace: @escaping () -> Bool, clock: any Clock<Duration>,
         onChange: @escaping (FileSnapshot?) -> Void, onUnavailable: @escaping (String?) -> Void) {
        self.url = url
        self.files = files
        self.inWorkspace = inWorkspace
        self.clock = clock
        self.onChange = onChange
        self.onUnavailable = onUnavailable
    }

    func start() {
        guard poll == nil else { return }
        schedule()
    }

    /// One poll after ``interval``, which schedules the next.
    private func schedule() {
        let clock = clock
        // task-owner: the tab's next poll of its file on the machine; stop() cancels it
        poll = Task { [weak self] in
            do {
                try await clock.sleep(for: Self.interval) // wakeup-allow: the daemon has no file events; one stat per interval while the tab shows a file of another machine
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.check()
            guard !Task.isCancelled, self.poll != nil else { return }
            self.schedule()
        }
    }

    func stop() {
        poll?.cancel()
        poll = nil
    }

    /// One poll: the file's revision, then its content when that moved (tests call it directly).
    func check() async {
        let path = url.path
        let stat: FileSystemStatRequest.Response
        do {
            stat = try await files.client.stat(path)
        } catch {
            switch files.openFailure(error) {
            case .notFound:
                available()
                revision = nil
                guard knownHash != nil else { return }
                knownHash = nil
                onChange(nil)
            case .unavailable(let reason):
                guard unavailable != reason else { return }
                unavailable = reason
                onUnavailable(reason)
            case .notFile, .tooLarge:
                available()
            }
            return
        }
        guard !Task.isCancelled else { return }
        available()
        guard stat.kind == "symlink" || stat.revision != revision else { return }
        let snapshot: (snapshot: FileSnapshot, revision: String?)
        do {
            snapshot = try await files.load(url, inWorkspace: inWorkspace())
        } catch {
            // The next poll tries again (the file may be mid-write); the revision stays unseen.
            return
        }
        guard !Task.isCancelled else { return }
        revision = snapshot.revision
        guard snapshot.snapshot.hash != knownHash else { return }
        knownHash = snapshot.snapshot.hash
        onChange(snapshot.snapshot)
    }

    private func available() {
        guard unavailable != nil else { return }
        unavailable = nil
        onUnavailable(nil)
    }
}
