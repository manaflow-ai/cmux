import CmuxNextCompat
import Darwin
import Foundation
import LocalAuthentication

/// Reads the Chromium framework's code and resources into the file cache on
/// the library-load thread, before `CefInitialize` runs on the main thread.
///
/// The framework binary is read BEFORE it is mapped (``readBinary(_:)``,
/// called ahead of `cef_load_library`). `dlopen` holds dyld's loader lock
/// while it maps the image, validates its signature and applies its fixups;
/// on a cold file cache (every nightly update) that took about 2 s, and
/// every main-thread `dlopen` or `dladdr` in that window waited for the lock
/// (Sentry MainThreadHang `__ulock_wait2` in `dyld4::APIs::dlopen_from` from
/// WebKit's Safe Browsing load, and `dyld_image_header_containing_address`
/// from `+[NSView clipsToBounds]`, 2-4 s after launch, the restored tab's
/// CEF load). Read first, the lock is held only for cached pages.
///
/// Mapping the framework (`dlopen`) does not read its code. On a cold file
/// cache `CefInitialize` and the first browser window then wait on page-ins
/// of the 367 MiB framework on the main thread: in a macOS 26 VM each held
/// the main thread for about 0.75 s with about 0.2 s of CPU, against about
/// 0.15 s each once the files were cached (os-smoke, 2026-10-18). After this
/// read, those page faults are served from memory. A cached file costs one
/// memory copy (about 40 ms for all files).
///
/// One system service Chromium asks synchronously on the main thread is
/// also asked here first, so its daemon is up: LocalAuthentication (the
/// first browser window creates an `LAContext`, a synchronous XPC that
/// waited about 0.5 s in a macOS 26 VM). `canEvaluatePolicy` only reports
/// whether a policy can be evaluated: it shows no prompt, asks for no
/// privacy permission (no TCC request; os-smoke checks the TCC log) and
/// changes no user-visible state. Location services are not asked (chief
/// decision 2026-10-18: no system access the user did not ask for).
nonisolated struct CEFFrameworkPrefetch: Sendable {
    struct Report: Sendable {
        var bytes: Int = 0
        var files: Int = 0
        var duration: Duration = .zero
        var services: Duration = .zero
        /// The binary read before the map (``readBinary(_:)``).
        var binary: Duration = .zero
        /// Time inside `cef_load_library`: how long dyld's loader lock was
        /// held for the framework (``noteMapped(_:)``).
        var map: Duration = .zero
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

    /// Reads the framework binary into the file cache (call off the main
    /// thread, before `cef_load_library`), so the map that follows holds
    /// dyld's loader lock only for cached pages.
    static func readBinary(_ layout: CEFRuntimeLayout) {
        let clock = ContinuousClock()
        let started = clock.now
        let binary = read([layout.frameworkBinary])
        let duration = clock.now - started
        lastReport.withLock { report in
            if report == nil { report = Report() }
            report?.binary = duration
            report?.bytes = binary.bytes
            report?.files = binary.files
        }
    }

    /// Records how long `cef_load_library` took (the loader-lock hold).
    static func noteMapped(_ duration: Duration) {
        lastReport.withLock { report in
            if report == nil { report = Report() }
            report?.map = duration
        }
    }

    /// Reads every file of `layout` but the binary (``readBinary(_:)`` read
    /// it before the map) once (call off the main thread), then primes
    /// ImageIO (`CEFRuntime.primeImageIO`).
    static func warm(_ layout: CEFRuntimeLayout) {
        // The service asks run beside the read and the start, never in its
        // way: a slow or hung daemon must not hold Chromium's start.
        // task-owner: one pair of system asks per process; nothing waits for them
        Task.detached(priority: .utility) {
            let clock = ContinuousClock()
            let started = clock.now
            _ = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
            let services = clock.now - started
            lastReport.withLock { report in
                if report == nil { report = Report() }
                report?.services = services
            }
        }
        let clock = ContinuousClock()
        let started = clock.now
        let resources = read(files(in: layout).filter { $0 != layout.frameworkBinary })
        let duration = clock.now - started
        lastReport.withLock { stored in
            var report = stored ?? Report()
            report.bytes += resources.bytes
            report.files += resources.files
            report.duration = report.binary + duration
            stored = report
        }
        CEFRuntime.primeImageIO()
    }

    /// Reads each file to its end; returns the bytes and files read.
    private static func read(_ urls: [URL]) -> (bytes: Int, files: Int) {
        var bytes = 0
        var files = 0
        let size = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16384)
        defer { buffer.deallocate() }
        for url in urls {
            // concurrency-allow: the library-load thread (Task.detached in CEFRuntime.start/preload), never the main thread
            let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            files += 1
            // concurrency-allow: the library-load thread, never the main thread
            while case let count = Darwin.read(descriptor, buffer, size), count > 0 || (count < 0 && errno == EINTR) {
                bytes += max(count, 0)
            }
        }
        return (bytes, files)
    }
}
