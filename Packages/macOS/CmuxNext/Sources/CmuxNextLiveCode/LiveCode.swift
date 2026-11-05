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
    var bundleID: String?
    /// Outside Debug and bench, only patches this app's team signed load.
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

    init(folder: LiveFolder) {
        self.folder = folder
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
        let path = folder.url.appendingPathComponent(name).path
        do {
            #if !DEBUG && !CMUX_BENCH_HOOKS
            // Outside Debug and bench, only a patch signed by this app's team loads (cmux#13742).
            try PatchSignature.check(path)
            #endif
            let handle = try Interposer.load(path)
            let patched = try Interposer.apply(handle: handle, dylib: path, current: &current)
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
            pid: getpid(), bundleID: Bundle.main.bundleIdentifier, teamSignedOnly: Self.teamSignedOnly,
            folder: folder.url.path, generation: generation, patches: applied.reversed().map(\.record),
            lastError: lastError, updatedAt: Date().timeIntervalSince1970)
        folder.writeStatus(status)
    }

    private static var teamSignedOnly: Bool {
        #if DEBUG || CMUX_BENCH_HOOKS
        false
        #else
        true
        #endif
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
