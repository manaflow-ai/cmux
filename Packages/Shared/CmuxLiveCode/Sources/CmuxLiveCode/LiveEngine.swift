// The live folder's engine: a running app takes new code for its Swift functions without a rebuild
// or a relaunch (docs/cmux-next/live-code.md). A patch is edited files compiled against this build
// and linked as a dylib (scripts/live-code/patch.py); dropped into the live folder, it is loaded,
// every function it defines that the app also defines is repointed to the new one (Interposer.swift),
// and the app's `redraw` runs. It works only in a live code build (scripts/live-code/build.sh for the
// macOS app, scripts/live-code/ios-sim.sh for the iPhone app in the iOS Simulator).
//
// The live folder is the whole interface, so `cmux live-code` (and its MCP tools) can repair the
// app when its UI is wedged: a new `*.dylib` applies, a new `NAME.load` applies the hidden
// `.NAME.dylib` beside it (for a transport that cannot rename a file into place: devicectl's copy into
// a phone's container, scripts/live-code/ios-device.sh), a new `*.rollback` undoes the newest patch,
// a new `*.rollback-all` undoes them all, and the app keeps `status.json` (what is applied) and
// `live-code.log` there. All of it runs on the engine actor, never on the main thread; only the
// redraw after a change is the app's, which sends it to the main thread without waiting for it.
// Shipped iPhone builds (Release, TestFlight, App Store) compile none of it: on iOS only a DEBUG
// build (Debug, or ios-sim.sh's Demo with DEBUG) has the engine, so a Release binary holds no
// loader, no interposer and no private dyld symbol name. The macOS app keeps it in every build.
#if os(macOS) || DEBUG
import Darwin
import Foundation

/// One applied patch, as `status.json` lists it.
struct LivePatchRecord: Codable, Sendable {
    var name: String
    /// From the patch's sidecar (`NAME.json`, which patch.py writes): the commit and files built.
    var commit: String?
    var files: [String]?
    var functions: Int
    var appliedAt: Double
}

/// `status.json`: what this process has applied, newest first.
struct LiveStatus: Codable, Sendable {
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
public actor LiveEngine {
    public let folder: LiveFolder
    private var source: (any DispatchSourceFileSystemObject)?
    private var seen = Set<String>()
    /// Each replaced function's newest code (Interposer.apply).
    private var current: [String: UnsafeRawPointer] = [:]
    /// The applied patches, oldest first: an undo takes the last one off.
    private var applied: [(patch: Interposer.Applied, record: LivePatchRecord)] = []
    private var generation = 0
    private var lastError: String?
    /// After each applied or undone patch, with the new generation: the app redraws (on its main
    /// thread, never waited for here).
    private let redraw: @Sendable (Int) -> Void
    #if os(macOS)
    /// Who signed this app, read once from its own code signature; nil in Debug and bench, which load
    /// any patch.
    private let signer: LiveCodeSigner?

    /// `signer` is nil in Debug and bench, which load any patch; the app decides, since only its own
    /// compilation conditions say which build it is.
    public init(folder: LiveFolder, signer: LiveCodeSigner?, redraw: @escaping @Sendable (Int) -> Void) {
        self.folder = folder
        self.signer = signer
        self.redraw = redraw
    }
    #else
    /// The iPhone app's live code builds are DEBUG builds. In the Simulator it loads any patch, ad hoc
    /// included; on a device dyld itself loads only a patch signed by the app's own team.
    public init(folder: LiveFolder, redraw: @escaping @Sendable (Int) -> Void) {
        self.folder = folder
        self.redraw = redraw
    }
    #endif

    /// Opens and watches the folder; false when it cannot.
    public func start() -> Bool {
        guard let opened = folder.open() else {
            folder.append("live code: cannot watch \(folder.url.path)")
            return false
        }
        // What is already there belongs to an earlier run, maybe of an older build: never load it.
        seen = Set(opened.names)
        source = folder.watch(opened.descriptor) { [weak self] names in
            guard let self else { return }
            Task { await self.found(names) }
        }
        say("watching \(folder.url.path) dyld_dynamic_interpose=\(Interposer.hasDynamicInterpose ? "yes" : "no, rebind only")")
        #if os(macOS)
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
        #endif
        writeStatus()
        return true
    }

    /// The folder's names after a change: each new one is handled once, in name order.
    func found(_ names: [String]) {
        for name in names where !seen.contains(name) {
            seen.insert(name)
            if name.hasSuffix(".rollback-all") {
                undo(name, all: true)
            } else if name.hasSuffix(".rollback") {
                undo(name, all: false)
            } else if name.hasSuffix(".load") {
                // The hidden patch was copied whole before this marker was.
                let base = String(name.dropLast(".load".count))
                apply("." + base + ".dylib", as: base + ".dylib")
            } else {
                apply(name, as: name)
            }
        }
    }

    /// Applies the folder's `file`, named `name` in the log and status.json.
    private func apply(_ file: String, as name: String) {
        let started = Date()
        do {
            // The check and the load read one private copy, never the shared folder's file twice.
            let copy = try folder.privateCopy(file)
            defer { try? FileManager.default.removeItem(at: copy) }
            #if os(macOS)
            // Outside Debug and bench, only a patch signed by this app's team loads, or, for an
            // unsigned app, any validly signed one (cmux#13742).
            if let signer {
                try PatchSignature.check(copy.path, app: signer)
            }
            #endif
            let handle = try Interposer.load(copy.path)
            let patched = try Interposer.apply(handle: handle, dylib: copy.path, current: &current)
            let sidecar = folder.sidecar(file)
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
        // Never waits on the main thread: a wedged one still gets the undo, and redraws when it can.
        redraw(generation)
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
        #if os(macOS)
        switch signer {
        case .team?, .unprotected?, .unreadable?: true
        case .noTeam?, nil: false
        }
        #else
        false
        #endif
    }
}

/// The live folder's disk side: its listing, its log (`live-code.log`) and `status.json`. Every
/// call reads or writes the disk: the engine actor makes them, off the main thread.
public struct LiveFolder: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Creates the folder and opens it for events; with the names it holds now.
    func open() -> (descriptor: Int32, names: [String])? {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter {
            !$0.hasPrefix(".") && ($0.hasSuffix(".dylib") || $0.hasSuffix(".load") || $0.hasSuffix(".rollback") || $0.hasSuffix(".rollback-all"))
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
            let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, min($0.count, size - copied)) }
            guard count > 0 else { throw LiveCodeError.copy("\(name) ended after \(copied) of \(size) bytes") }
            guard buffer.withUnsafeBytes({ Self.writeAll(target, $0.baseAddress, count) }) else {
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

    /// `NAME.json` beside the patch `NAME.dylib` (`.NAME.json` beside a hidden `.NAME.dylib`), when
    /// patch.py wrote one.
    func sidecar(_ name: String) -> Sidecar? {
        guard name.hasSuffix(".dylib") else { return nil }
        let json = url.appendingPathComponent(String(name.dropLast(".dylib".count)) + ".json")
        guard let data = try? Data(contentsOf: json) else { return nil }
        return try? JSONDecoder().decode(Sidecar.self, from: data)
    }

    func writeStatus(_ status: LiveStatus) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(status) else { return }
        try? data.write(to: url.appendingPathComponent("status.json"), options: .atomic)
    }

    /// Appends one line to `live-code.log`.
    public func append(_ line: String) {
        let descriptor = Darwin.open(url.appendingPathComponent("live-code.log").path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return }
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { Self.writeAll(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
    }

    /// Writes all `count` bytes, retrying a short write or an interrupted one.
    private static func writeAll(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Bool {
        guard let buffer else { return count == 0 }
        var written = 0
        while written < count {
            let result = Darwin.write(descriptor, buffer + written, count - written)
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { return false }
            written += result
        }
        return true
    }
}
#endif
