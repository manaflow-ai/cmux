import CmuxNextCompat
import Darwin
import Foundation

/// Reads the Chromium framework's code and resources into the file cache on
/// the library-load thread, before `CefInitialize` runs on the main thread.
///
/// Mapping the framework (`dlopen`) does not read its code. On a cold file
/// cache `CefInitialize` and the first browser window then wait on page-ins
/// of the 367 MiB framework on the main thread: in a macOS 26 VM each held
/// the main thread for about 0.75 s with about 0.2 s of CPU, against about
/// 0.15 s each once the files were cached (os-smoke, 2026-10-18). After this
/// read, those page faults are served from memory. A cached file costs one
/// memory copy (about 40 ms for all files).
nonisolated struct CEFFrameworkPrefetch: Sendable {
    struct Report: Sendable {
        var bytes: Int = 0
        var files: Int = 0
        var duration: Duration = .zero
    }

    /// The last read in this process (`debug.cef`).
    static var last: Report? { lastReport.withLock { $0 } }
    private static let lastReport = Mutex<Report?>(nil)

    /// The framework binary and the top-level files of its Resources folder
    /// (pak files, ICU data, V8 snapshots). Locale folders are left out.
    static func files(in layout: CEFRuntimeLayout) -> [URL] {
        let resources = layout.frameworkDirectory.appending(path: "Resources")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? []
        let resourceFiles = names.sorted().map { resources.appending(path: $0) }.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        return [layout.frameworkBinary] + resourceFiles
    }

    /// Reads every file of `layout` once (call off the main thread), then
    /// primes ImageIO (`CEFRuntime.primeImageIO`).
    static func warm(_ layout: CEFRuntimeLayout) {
        let clock = ContinuousClock()
        let started = clock.now
        var report = Report()
        let size = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16384)
        defer { buffer.deallocate() }
        for url in files(in: layout) {
            // concurrency-allow: the library-load thread (Task.detached in CEFRuntime.start/preload), never the main thread
            let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            report.files += 1
            // concurrency-allow: the library-load thread, never the main thread
            while case let count = read(descriptor, buffer, size), count > 0 {
                report.bytes += count
            }
        }
        report.duration = clock.now - started
        lastReport.withLock { $0 = report }
        CEFRuntime.primeImageIO()
    }
}
