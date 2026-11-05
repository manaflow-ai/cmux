// Live code in the app: a running cmux NEXT takes new code for its Swift functions without a
// rebuild or a relaunch, as the view shell does (Prototypes/ViewShell/README.md, "Live code"). A
// patch is edited files compiled against this build and linked as a dylib
// (scripts/live-code/patch.py); dropped into the live folder, it is loaded, every function it
// defines that the app also defines is repointed to the new one (Interposer.swift), and every
// window redraws. It works only in a build linked for it (`-interposable`, exported symbols,
// CmuxNextApp unoptimized; reload.sh with CMUX_LIVE_CODE_BUILD=1).
//
// The app delegate holds the one instance. It watches only in a Debug or bench build, when
// CMUX_LIVE_CODE_DIR names the live folder. The proof of the path comes first
// (scripts/measure/live-code-app.sh); the check of who may publish a patch (cmux#13742) comes
// before a NIGHTLY watches.
import AppKit
import CmuxNextCompat
import Foundation

/// The live folder's watcher: applies each new patch, then redraws every window.
@MainActor
public final class LiveCode {
    /// Watches the folder CMUX_LIVE_CODE_DIR names. Only Debug and bench builds watch until a
    /// patch's signed pointer is checked (cmux#13742).
    public static func fromEnvironment() -> LiveCode {
        let live = LiveCode()
        #if DEBUG || CMUX_BENCH_HOOKS
        if let path = ProcessInfo.processInfo.environment["CMUX_LIVE_CODE_DIR"], !path.isEmpty {
            live.watch(LiveFolder(url: URL(fileURLWithPath: path, isDirectory: true)))
        }
        #endif
        return live
    }

    /// Patches applied so far.
    public private(set) var generation = 0
    private var folder: LiveFolder?
    private var source: (any DispatchSourceFileSystemObject)?
    private var loaded = Set<String>()
    /// Each replaced function's newest code (Interposer.apply).
    private var current: [String: UnsafeRawPointer] = [:]

    /// Watches `folder` for patch dylibs (`*.dylib`, each a new name) and applies each once. The
    /// folder's disk work runs off the main thread; only the patch is applied on the main actor.
    private func watch(_ folder: LiveFolder) {
        self.folder = folder
        Task.detached(priority: .utility) {
            let opened = folder.open()
            await MainActor.run { self.started(folder, opened) }
        }
    }

    private func started(_ folder: LiveFolder, _ opened: (descriptor: Int32, names: [String])?) {
        guard let opened else {
            say("cannot watch \(folder.url.path)")
            return
        }
        // Patches already there belong to an earlier run of an older build: never load them.
        loaded = Set(opened.names)
        source = folder.watch(opened.descriptor) { [weak self] names in
            Task { @MainActor in self?.found(names) }
        }
        say("watching \(folder.url.path)")
    }

    /// Every window's views draw and lay out again, now: their next `updateLayer`, `draw` and
    /// `layout` run the patch's code. Says when, so the harness can time the edit to the redraw.
    private func redraw() {
        for window in NSApp.windows where window.isVisible {
            if let content = window.contentView { Self.invalidate(content) }
            window.displayIfNeeded()
        }
        say("redrawn generation=\(generation) at=\(Date().timeIntervalSince1970)")
    }

    private static func invalidate(_ view: NSView) {
        view.needsDisplay = true
        view.needsLayout = true
        for subview in view.subviews { invalidate(subview) }
    }

    private func say(_ line: String) {
        NSLog("cmux live code: %@", line)
        folder?.append("live code: \(line)\n")
    }

    /// The folder's patch names after a change: each new one is applied once.
    private func found(_ names: [String]) {
        guard let folder else { return }
        for name in names where !loaded.contains(name) {
            loaded.insert(name)
            apply(folder.url.appendingPathComponent(name))
        }
    }

    private func apply(_ patch: URL) {
        let started = Date()
        let path = patch.path
        Task.detached(priority: .userInitiated) {
            let loaded = Result { try Interposer.load(path) }
            await MainActor.run { self.applyLoaded(loaded, patch: patch, started: started) }
        }
    }

    private func applyLoaded(_ loaded: Result<Int, any Error>, patch: URL, started: Date) {
        do {
            let count = try Interposer.apply(handle: loaded.get(), dylib: patch.path, current: &current)
            generation += 1
            let ms = Int((Date().timeIntervalSince(started) * 1000).rounded())
            say("applied \(patch.lastPathComponent) functions=\(count) load_ms=\(ms) at=\(Date().timeIntervalSince1970)")
            redraw()
        } catch {
            say("\(patch.lastPathComponent) refused: \(error)")
        }
    }
}

/// The live folder's disk side, off the main thread: its listing and its log (`live-code.log`,
/// which a harness reads). Nonisolated: it runs in detached tasks and on a global queue.
nonisolated struct LiveFolder: Sendable {
    let url: URL

    /// Creates the folder and opens it for events; with the patch names it holds now.
    func open() -> (descriptor: Int32, names: [String])? {
        try? FileManager.checked.createDirectory(at: url, withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        return descriptor >= 0 ? (descriptor, patches()) : nil
    }

    /// Calls `changed` on a utility queue with the patch names after each change of the folder.
    func watch(_ descriptor: Int32, _ changed: @escaping @Sendable ([String]) -> Void) -> any DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .global(qos: .utility))
        source.setEventHandler { changed(patches()) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    func patches() -> [String] {
        ((try? FileManager.checked.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.hasSuffix(".dylib") && !$0.hasPrefix(".") }.sorted()
    }

    func append(_ line: String) {
        let log = url.appendingPathComponent("live-code.log").path
        Task.detached(priority: .utility) {
            let descriptor = Darwin.open(log, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard descriptor >= 0 else { return }
            let bytes = Array(line.utf8)
            _ = bytes.withUnsafeBytes { blockingWrite(descriptor, $0.baseAddress, $0.count) }
            close(descriptor)
        }
    }
}
