// Live code in the app: a running cmux NEXT takes new code for its Swift functions without a
// rebuild or a relaunch, as the view shell does (Prototypes/ViewShell/README.md, "Live code"). A
// patch is edited files compiled against this build and linked as a dylib
// (scripts/live-code/patch.py); dropped into the live folder, it is loaded, every function it
// defines that the app also defines is repointed to the new one (Interposer.swift), and every
// window redraws. It works only in a live code build (scripts/live-code/build.sh).
//
// The live folder is the whole interface, so `cmux live-code` (and its MCP tools) can repair the
// app when its UI is wedged: a new `*.dylib` applies, a new `*.rollback` undoes the newest patch,
// a new `*.rollback-all` undoes them all, and the app keeps `status.json` (what is applied) and
// `live-code.log` there. All of it runs on the engine actor, never on the main thread; only the
// redraw after a change is sent to the main thread, without waiting for it.
//
// The app delegate holds the one instance. Debug and bench builds watch, and a live code build of
// a NIGHTLY (CMUX_LIVE_CODE), which loads only patches its own team signed (PatchSignature.swift).
import AppKit
import CmuxNextCompat
import Foundation

/// The live folder's watcher, as the app delegate holds it.
@MainActor
public final class LiveCode {
    /// Watches the folder CMUX_LIVE_CODE_DIR names.
    public static func fromEnvironment() -> LiveCode {
        let live = LiveCode()
        #if DEBUG || CMUX_BENCH_HOOKS || CMUX_LIVE_CODE
        if let path = ProcessInfo.processInfo.environment["CMUX_LIVE_CODE_DIR"], !path.isEmpty {
            live.watch(LiveFolder(url: URL(fileURLWithPath: path, isDirectory: true)))
        }
        #endif
        return live
    }

    /// Labs > Live Code (`labs.liveCode`, read at launch): with the switch on, watches the person's
    /// live folder (``LiveFolder/standard``), unless CMUX_LIVE_CODE_DIR already named one. Off,
    /// nothing changes.
    public func labsSwitch(_ on: Bool) {
        #if DEBUG || CMUX_BENCH_HOOKS || CMUX_LIVE_CODE
        guard on, engine == nil else { return }
        watch(LiveFolder.standard)
        #endif
    }

    private var engine: LiveEngine?

    private func watch(_ folder: LiveFolder) {
        let engine = LiveEngine(folder: folder)
        self.engine = engine
        Task.detached(priority: .utility) { await engine.start() }
    }

    /// Every window's views draw and lay out again: their next `updateLayer`, `draw` and `layout`
    /// run the new code. Logs when, so a harness can time a change to the redraw.
    static func redraw(generation: Int, folder: LiveFolder) {
        for window in NSApp.windows where window.isVisible {
            if let content = window.contentView { invalidate(content) }
            window.displayIfNeeded()
        }
        let line = "live code: redrawn generation=\(generation) at=\(Date().timeIntervalSince1970)"
        Task.detached(priority: .utility) { folder.append(line) }
    }

    private static func invalidate(_ view: NSView) {
        view.needsDisplay = true
        view.needsLayout = true
        for subview in view.subviews { invalidate(subview) }
    }
}

/// One applied patch, as `status.json` lists it.
nonisolated struct LivePatchRecord: Codable, Sendable {
    var name: String
    /// From the patch's sidecar (`NAME.json`, which patch.py writes): the commit and files built.
    var commit: String?
    var files: [String]?
    var functions: Int
    var appliedAt: Double
}

/// `status.json`: what this process has applied, newest first.
nonisolated struct LiveStatus: Codable, Sendable {
    var pid: Int32
    /// The process's executable, so a reader can tell a reused pid from this app.
    var executable: String?
    var bundleID: String?
    /// Only patches this app's team signed load: outside Debug and bench, in an app signed by a team.
    var teamSignedOnly: Bool
    var folder: String
    var generation: Int
    var patches: [LivePatchRecord]
    var lastError: String?
    var updatedAt: Double
}

/// The live folder's changes, applied one at a time off the main thread.
actor LiveEngine {
    let folder: LiveFolder
    private var source: (any DispatchSourceFileSystemObject)?
    private var seen = Set<String>()
    /// Each replaced function's newest code (Interposer.apply).
    private var current: [String: UnsafeRawPointer] = [:]
    /// The applied patches, oldest first: an undo takes the last one off.
    private var applied: [(patch: Interposer.Applied, record: LivePatchRecord)] = []
    private var generation = 0
    private var lastError: String?
    /// Who signed this app, read once from its own code signature; nil in Debug and bench, which load
    /// any patch.
    private let signer: PatchSignature.AppSigner?

    init(folder: LiveFolder) {
        self.folder = folder
        #if DEBUG || CMUX_BENCH_HOOKS
        signer = nil
        #else
        signer = PatchSignature.runningSigner()
        #endif
    }

    func start() {
        guard let opened = folder.open() else {
            folder.append("live code: cannot watch \(folder.url.path)")
            return
        }
        // What is already there belongs to an earlier run, maybe of an older build: never load it.
        seen = Set(opened.names)
        source = folder.watch(opened.descriptor) { [weak self] names in
            guard let self else { return }
            Task { await self.found(names) }
        }
        say("watching \(folder.url.path)")
        switch signer {
        case .noTeam?:
            say("this app is unsigned (its signature names no team): any validly signed patch loads, ad hoc included")
        case .unreadable(let detail)?:
            say("this app's own signature is unreadable (\(detail)): every patch is refused")
        case .unprotected(let team, let why)?:
            say("this app (team \(team)) runs without library validation (\(why)): every patch is refused")
        case .team?, nil:
            break
        }
        writeStatus()
    }

    /// The folder's names after a change: each new one is handled once, in name order.
    func found(_ names: [String]) {
        for name in names where !seen.contains(name) {
            seen.insert(name)
            if name.hasSuffix(".rollback-all") {
                undo(name, all: true)
            } else if name.hasSuffix(".rollback") {
                undo(name, all: false)
            } else {
                apply(name)
            }
        }
    }

    private func apply(_ name: String) {
        let started = Date()
        do {
            // The check and the load read one private copy, never the shared folder's file twice.
            let copy = try folder.privateCopy(name)
            defer { try? FileManager.checked.removeItem(at: copy) }
            // Outside Debug and bench, only a patch signed by this app's team loads, or, for an
            // unsigned app, any validly signed one (cmux#13742).
            if let signer {
                try PatchSignature.check(copy.path, app: signer)
            }
            let handle = try Interposer.load(copy.path)
            let patched = try Interposer.apply(handle: handle, dylib: copy.path, current: &current)
            let sidecar = folder.sidecar(name)
            let record = LivePatchRecord(name: name, commit: sidecar?.commit, files: sidecar?.files,
                                         functions: patched.after.count, appliedAt: Date().timeIntervalSince1970)
            applied.append((patched, record))
            let ms = Int((Date().timeIntervalSince(started) * 1000).rounded())
            changed("applied \(name) functions=\(record.functions) load_ms=\(ms) at=\(Date().timeIntervalSince1970)")
        } catch {
            refused(name, error)
        }
    }

    /// The code from before the newest patch (or before every patch) runs again, in this process.
    private func undo(_ name: String, all: Bool) {
        let started = Date()
        guard !applied.isEmpty else {
            refused(name, LiveCodeError.nothingToUndo)
            return
        }
        var count = 0
        do {
            for _ in 0..<(all ? applied.count : 1) {
                guard let last = applied.last else { break }
                count += try Interposer.revert(last.patch, current: &current)
                applied.removeLast()
            }
            let ms = Int((Date().timeIntervalSince(started) * 1000).rounded())
            changed("rolled back \(name) functions=\(count) rollback_ms=\(ms) left=\(applied.count) at=\(Date().timeIntervalSince1970)")
        } catch {
            refused(name, error)
        }
    }

    private func changed(_ line: String) {
        generation += 1
        lastError = nil
        say(line)
        writeStatus()
        let (generation, folder) = (generation, folder)
        // Never waits on the main thread: a wedged one still gets the undo, and redraws when it can.
        Task { @MainActor in LiveCode.redraw(generation: generation, folder: folder) }
    }

    private func refused(_ name: String, _ error: any Error) {
        lastError = "\(name): \(error)"
        say("\(name) refused: \(error)")
        writeStatus()
    }

    private func say(_ line: String) {
        NSLog("cmux live code: %@", line)
        folder.append("live code: \(line)")
    }

    private func writeStatus() {
        let status = LiveStatus(
            pid: getpid(), executable: Bundle.main.executablePath, bundleID: Bundle.main.bundleIdentifier, teamSignedOnly: teamSignedOnly,
            folder: folder.url.path, generation: generation, patches: applied.reversed().map(\.record),
            lastError: lastError, updatedAt: Date().timeIntervalSince1970)
        folder.writeStatus(status)
    }

    private var teamSignedOnly: Bool {
        switch signer {
        case .team?, .unprotected?, .unreadable?: true
        case .noTeam?, nil: false
        }
    }
}

/// The live folder's disk side: its listing, its log (`live-code.log`) and `status.json`.
nonisolated struct LiveFolder: Sendable {
    let url: URL

    /// The person's live folder, where `cmux live-code` looks by default.
    static var standard: LiveFolder {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return LiveFolder(url: caches.appendingPathComponent("cmux-next/live-code", isDirectory: true))
    }

    /// Creates the folder and opens it for events; with the names it holds now.
    func open() -> (descriptor: Int32, names: [String])? {
        try? FileManager.checked.createDirectory(at: url, withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        return descriptor >= 0 ? (descriptor, entries()) : nil
    }

    /// Calls `changed` on a utility queue with the folder's names after each change.
    func watch(_ descriptor: Int32, _ changed: @escaping @Sendable ([String]) -> Void) -> any DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .global(qos: .utility))
        source.setEventHandler { changed(entries()) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    /// Patches and undo requests, in name order. A hidden name is a file still being written.
    func entries() -> [String] {
        ((try? FileManager.checked.contentsOfDirectory(atPath: url.path)) ?? []).filter {
            !$0.hasPrefix(".") && ($0.hasSuffix(".dylib") || $0.hasSuffix(".rollback") || $0.hasSuffix(".rollback-all"))
        }.sorted()
    }

    /// A private copy of the patch `name`, which the signature check and dlopen both read. The
    /// live folder is writable by any process of this user, and the NIGHTLY's entitlements turn off
    /// dyld's library validation (`disable-library-validation`), so checking the folder's file and
    /// then opening its path again could see two files. The patch is read without following a link
    /// and must be a regular file; the copy is created exclusively in a 0700 folder of this process
    /// in the per-user temporary directory, which must be a directory this user owns that nobody
    /// else can enter. The caller removes the copy once it is loaded (dyld keeps the mapping).
    func privateCopy(_ name: String) throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-live-code-\(getpid())", isDirectory: true)
        if mkdir(folder.path, 0o700) != 0, errno != EEXIST {
            throw LiveCodeError.copy("cannot make \(folder.path): errno \(errno)")
        }
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else {
            throw LiveCodeError.copy("\(folder.path) is not a folder only this user can enter")
        }
        let source = Darwin.open(url.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW)
        guard source >= 0 else { throw LiveCodeError.copy("cannot open \(name) without following a link: errno \(errno)") }
        defer { close(source) }
        guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw LiveCodeError.copy("\(name) is not a regular file")
        }
        let copy = folder.appendingPathComponent(UUID().uuidString + ".dylib")
        let target = Darwin.open(copy.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard target >= 0 else { throw LiveCodeError.copy("cannot create \(copy.path): errno \(errno)") }
        defer { close(target) }
        let size = Int(info.st_size)
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var copied = 0
        // Bounded by the size fstat gave; a file that grows meanwhile is copied only that far.
        for _ in 0...(size / buffer.count) where copied < size {
            // concurrency-allow: called only from LiveEngine, an actor off the main thread
            let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, min($0.count, size - copied)) }
            guard count > 0 else { throw LiveCodeError.copy("\(name) ended after \(copied) of \(size) bytes") }
            guard buffer.withUnsafeBytes({ blockingWrite(target, $0.baseAddress, count) }) == count else {
                throw LiveCodeError.copy("cannot write \(copy.path): errno \(errno)")
            }
            copied += count
        }
        guard copied == size else { throw LiveCodeError.copy("\(name) ended after \(copied) of \(size) bytes") }
        return copy
    }

    struct Sidecar: Decodable {
        var commit: String?
        var files: [String]?
    }

    /// `NAME.json` beside the patch `NAME.dylib`, when patch.py wrote one.
    func sidecar(_ name: String) -> Sidecar? {
        guard name.hasSuffix(".dylib") else { return nil }
        let json = url.appendingPathComponent(String(name.dropLast(".dylib".count)) + ".json")
        guard let data = try? Data(blockingContentsOf: json) else { return nil }
        return try? JSONDecoder().decode(Sidecar.self, from: data)
    }

    func writeStatus(_ status: LiveStatus) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(status) else { return }
        try? data.blockingWrite(to: url.appendingPathComponent("status.json"), options: .atomic)
    }

    /// Appends one line to `live-code.log`.
    func append(_ line: String) {
        let descriptor = Darwin.open(url.appendingPathComponent("live-code.log").path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return }
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { blockingWrite(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
    }
}
