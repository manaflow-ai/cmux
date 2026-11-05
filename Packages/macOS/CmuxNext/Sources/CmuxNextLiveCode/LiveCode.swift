// Live code in the app: a running cmux NEXT takes new code for its Swift functions without a
// rebuild or a relaunch, as the view shell does (Prototypes/ViewShell/README.md, "Live code"). A
// patch is edited files compiled against this build and linked as a dylib
// (scripts/live-code/patch.sh); dropped into the live folder, it is loaded, every function it
// defines that the app also defines is repointed to the new one (Interposer.swift), and the views
// that read ``LiveCode/generation`` redraw. It works only in a build linked for it (`-interposable`,
// exported symbols, no inlining across functions; reload.sh's bench configuration with
// CMUX_LIVE_CODE_BUILD=1).
//
// It starts only when CMUX_LIVE_CODE_DIR names the live folder, at the first use of
// ``LiveCode/shared`` (a view's `liveCodeRedraw()`, CmuxNextDesign). The proof of the path comes
// first (scripts/measure/live-code-app.sh); the check of who may publish a patch comes before it
// reaches anyone's app.
public import Combine
import Foundation

/// What the views observe: `generation` goes up after each applied patch.
@MainActor
public final class LiveCode: ObservableObject {
    /// Watches the folder CMUX_LIVE_CODE_DIR names, from its first use (a view's ``liveCodeRedraw()``).
    public static let shared: LiveCode = {
        let live = LiveCode()
        if let path = ProcessInfo.processInfo.environment["CMUX_LIVE_CODE_DIR"], !path.isEmpty {
            live.watch(URL(fileURLWithPath: path, isDirectory: true))
        }
        return live
    }()

    @Published public private(set) var generation = 0
    /// Each replaced function's newest code (Interposer.apply).
    private var current: [String: UnsafeRawPointer] = [:]
    private var source: (any DispatchSourceFileSystemObject)?
    private var loaded = Set<String>()
    private var log: FileHandle?

    /// Watches `folder` for patch dylibs (`*.dylib`, each a new name) and applies each once.
    /// Each line it says also goes to `folder/live-code.log`, which a harness reads.
    func watch(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let logFile = folder.appendingPathComponent("live-code.log")
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        log = try? FileHandle(forWritingTo: logFile)
        _ = try? log?.seekToEnd()
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            say("cannot watch \(folder.path)")
            return
        }
        // Patches already there belong to an earlier run of an older build: never load them.
        loaded = Set(Self.patches(in: folder))
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scan(folder) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        say("watching \(folder.path)")
    }

    /// After a generation's views are rebuilt: a view that reads ``generation`` calls this from its
    /// next layout, so the harness can time the edit to the redraw.
    public func drawn() {
        say("redrawn generation=\(generation) at=\(Date().timeIntervalSince1970)")
    }

    private func say(_ line: String) {
        NSLog("cmux live code: %@", line)
        log?.write(Data("live code: \(line)\n".utf8))
    }

    private static func patches(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".dylib") && !$0.hasPrefix(".") }.sorted()
    }

    private func scan(_ folder: URL) {
        for name in Self.patches(in: folder) where !loaded.contains(name) {
            loaded.insert(name)
            apply(folder.appendingPathComponent(name))
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
        } catch {
            say("\(patch.lastPathComponent) refused: \(error)")
        }
    }
}
