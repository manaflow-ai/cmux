import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Foundation
import ImageIO
import LocalAuthentication
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

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
/// A predicted start (``CEFRuntime/preload(layout:)``, with feature
/// `cefPrefetchBehindFence`) does not read at once: ``post(_:on:)`` queues the
/// read as ``WorkPriority/idle`` items on the files lane, which the startup
/// best-effort fence holds, so a cold launch with no visible Chromium page reads
/// no Chromium file before the reveal. A start someone waits for (a tab,
/// a user feature) calls ``promote(on:)``: what is not read yet is read at
/// ``WorkPriority/userBlocking`` (awaited items, which the fence never holds)
/// and the idle reader stops after its current chunk. Readers claim chunks, so
/// no byte is read twice. Chrome: an after-startup BEST_EFFORT task
/// (chrome/browser/after_startup_task_utils.cc;
/// base/task/thread_pool/thread_pool_instance.h `BeginBestEffortFence`); a
/// queued ThreadPool task keeps its priority, so the caller that needs the
/// result now does the work itself.
///
/// One system service Chromium asks synchronously on the main thread is
/// also asked here first, so its daemon is up: LocalAuthentication (the
/// first browser window creates an `LAContext`, a synchronous XPC that
/// waited about 0.5 s in a macOS 26 VM). `canEvaluatePolicy` only reports
/// whether a policy can be evaluated: it shows no prompt, asks for no
/// privacy permission (no TCC request; os-smoke checks the TCC log) and
/// changes no user-visible state. Location services are not asked (chief
/// decision 2026-10-18: no system access the user did not ask for).
///
/// One per runtime (``CEFRuntime/prefetch``); tests make their own.
nonisolated final class CEFFrameworkPrefetch: Sendable {
    nonisolated struct Report: Sendable {
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

    /// How a bounded read ended.
    nonisolated enum Outcome: Sendable, Equatable {
        /// Every byte of every file is claimed.
        case done
        /// `stop` ended it: a promotion took over.
        case stopped
        /// It read its byte budget and bytes are left.
        case budgetSpent
    }

    /// Bytes a reader claims at a time: the unit two readers (the idle one and a promotion) split a file by.
    static let chunkBytes = 4 << 20
    /// Bytes one lane item reads before it ends (the idle reader then posts the next item, a promotion runs
    /// the next), so one item stays inside the files lane's hang deadline (``BackgroundWork/hangDeadline(_:)``)
    /// even with the idle level's throttled I/O on a cold disk.
    static let itemBudget = 64 << 20

    nonisolated private struct State {
        /// The layout ``post(_:on:)`` queued a read of; nil while no idle read is queued.
        var layout: CEFRuntimeLayout?
        /// Per file, the offset up to which readers claimed it.
        var claimed: [URL: Int] = [:]
        /// Files whose every byte a reader claimed (or that would not open): no reader opens them again.
        var done: Set<URL> = []
        /// The reads ended (``finish(droppedAtShutdown:)``): ``finished()`` returns at once.
        var finished = false
        /// Shutdown dropped the idle read: the load that waits for it maps nothing.
        var droppedAtShutdown = false
        var waiters: [OnceContinuation<Bool, OnceContinuationError>] = []
        var report: Report?
    }

    // concurrency-allow: the claims, the waiters and the report, taken by lane readers and the main actor (lock carve-out: a dictionary, a set, an array and a value; no I/O and no resume under it).
    private let state = Mutex(State())
    /// Set by ``promote(on:)``: the idle reader stops after its current chunk.
    private let promoted = Atomic<Bool>(false)

    init() {}

    /// The reads so far (`debug.cef`); nil before any.
    var last: Report? { state.withLock { $0.report } }

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

    /// Reads the binary's unread chunks into the file cache (call off the main
    /// thread, before `cef_load_library`), so the map that follows holds
    /// dyld's loader lock only for cached pages.
    func readBinary(_ layout: CEFRuntimeLayout) {
        noteBinary(read([layout.frameworkBinary]).elapsed)
    }

    /// Records how long `cef_load_library` took (the loader-lock hold).
    func noteMapped(_ duration: Duration) {
        state.withLock { state in
            var report = state.report ?? Report()
            report.map = duration
            state.report = report
        }
    }

    /// Reads the unread chunks of every file of `layout` but the binary (``readBinary(_:)`` read it before the
    /// map; call off the main thread), then primes ImageIO (``primeImageIO()``).
    func warm(_ layout: CEFRuntimeLayout) {
        // The service asks run beside the read and the start, never in its
        // way: a slow or hung daemon must not hold Chromium's start.
        // task-owner: one pair of system asks per process; nothing waits for them
        Task.detached(priority: .utility) { [self] in
            let clock = ContinuousClock()
            let started = clock.now
            _ = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
            let services = clock.now - started
            state.withLock { state in
                var report = state.report ?? Report()
                report.services = services
                state.report = report
            }
        }
        _ = read(Array(Self.files(in: layout).dropFirst()))
        Self.primeImageIO()
    }

    /// Queues the read of `layout` (the binary, then the resources) as ``WorkPriority/idle`` items of at most
    /// ``itemBudget`` bytes on `work`'s files lane: the best-effort fence holds them until the reveal.
    /// ``finished()`` returns when they, or a ``promote(on:)``, read everything. Once per prefetch; a later
    /// call queues nothing.
    func post(_ layout: CEFRuntimeLayout, on work: BackgroundWork) {
        let first = state.withLock { state -> Bool in
            guard state.layout == nil, !state.finished else { return false }
            state.layout = layout
            return true
        }
        if first { postStep(layout, on: work) }
    }

    /// ``post(_:on:)``, and one task of `work` (quit cancels it) that returns what ``finished()`` returns.
    func postAwaited(_ layout: CEFRuntimeLayout, on work: BackgroundWork) -> Task<Bool, any Error> {
        post(layout, on: work)
        return work.task(.bestEffort) { @Sendable [self] () async -> Bool in await finished() }
    }

    /// One idle item; it posts the next until every byte is read or a promotion takes over.
    private func postStep(_ layout: CEFRuntimeLayout, on work: BackgroundWork) {
        // Dropped at shutdown (the app quits): the preload that waits for the read maps nothing.
        work.post(.idle, mayBlock: .files, abandoned: { [self] in finish(droppedAtShutdown: true) }) { [self] in
            switch readAll(layout, budget: Self.itemBudget, stop: { self.promoted.load(ordering: .relaxed) }) {
            case .done: finish()
            case .budgetSpent: postStep(layout, on: work)
            case .stopped: break // the promotion reads the rest and finishes
            }
        }
    }

    /// Someone waits for Chromium now: reads what the idle items have not, at ``WorkPriority/userBlocking`` on
    /// `work`'s files lane (awaited items, so the fence never holds them), and stops the idle reader after its
    /// current chunk. Returns at once when no idle read was queued or everything is read. When an item is
    /// refused (the caller's task was cancelled), the reads end here and the load reads what is left itself.
    /// Returns false when shutdown dropped the idle read first (nothing should map), else true.
    @discardableResult
    func promote(on work: BackgroundWork) async -> Bool {
        if let layout = state.withLock({ $0.finished ? nil : $0.layout }) {
            promoted.store(true, ordering: .relaxed)
            var outcome = Outcome.budgetSpent
            while outcome == .budgetSpent {
                outcome = (try? await work.run(.userBlocking, mayBlock: .files) { [self] in
                    readAll(layout, budget: Self.itemBudget, stop: { false })
                }) ?? .stopped
            }
            finish()
        }
        return state.withLock { !$0.droppedAtShutdown }
    }

    /// True once ``promote(on:)`` took over the read: someone waits for Chromium, so the map that follows the read
    /// runs at user-initiated.
    var isPromoted: Bool { promoted.load(ordering: .relaxed) }

    /// Returns once ``post(_:on:)``'s read or a ``promote(on:)`` ended: true to map the framework, false when
    /// shutdown dropped the read (the app quits; nothing should map).
    func finished() async -> Bool {
        // A waiter dropped unresumed (abandoned) maps, as a load with no prefetch does.
        let map = try? await withOnceContinuation { (continuation: OnceContinuation<Bool, OnceContinuationError>) in
            let now = state.withLock { state -> Bool? in
                if state.finished { return !state.droppedAtShutdown }
                state.waiters.append(continuation)
                return nil
            }
            if let now { continuation.resume(returning: now) }
        }
        return map ?? true
    }

    /// Ends the reads and resumes every ``finished()`` waiter (outside the lock). The first end decides.
    private func finish(droppedAtShutdown: Bool = false) {
        let (waiters, map) = state.withLock { state -> ([OnceContinuation<Bool, OnceContinuationError>], Bool) in
            if !state.finished {
                state.finished = true
                state.droppedAtShutdown = droppedAtShutdown
            }
            defer { state.waiters = [] }
            return (state.waiters, !state.droppedAtShutdown)
        }
        for waiter in waiters { waiter.resume(returning: map) }
    }

    /// The binary, then the resources, at most about `budget` bytes.
    private func readAll(_ layout: CEFRuntimeLayout, budget: Int, stop: () -> Bool) -> Outcome {
        let binary = read([layout.frameworkBinary], budget: budget, stop: stop)
        noteBinary(binary.elapsed)
        guard binary.outcome == .done else { return binary.outcome }
        return read(Array(Self.files(in: layout).dropFirst()), budget: budget - binary.bytes, stop: stop).outcome
    }

    /// Adds `elapsed` to the time spent on the binary.
    private func noteBinary(_ elapsed: Duration) {
        state.withLock { state in
            var report = state.report ?? Report()
            report.binary += elapsed
            state.report = report
        }
    }

    /// The first Chromium window decodes its first image with
    /// `-[NSImage initWithData:]` on the main thread, and ImageIO builds its
    /// process-wide plugin list on first use (about 70 ms measured). Asking
    /// for an image type here builds that list on this background thread.
    static func primeImageIO() {
        // A 1x1 PNG header is enough for the type sniff.
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        _ = CheckedImageSource(Data(png))?.type
    }

    /// Reads the chunks of `urls` no reader claimed, until every byte is claimed, `stop` is true (checked
    /// between chunks) or `budget` bytes are read; adds the bytes, the files it finished and the time to the report.
    private func read(_ urls: [URL], budget: Int = .max,
                      stop: () -> Bool = { false }) -> (outcome: Outcome, bytes: Int, elapsed: Duration) {
        let clock = ContinuousClock()
        let started = clock.now
        var bytes = 0
        var files = 0
        var outcome = Outcome.done
        let size = 1 << 20
        // SAFETY: this reader's own page-aligned scratch buffer of `size` bytes, freed once when the read ends;
        // only pread writes it (`read(_:from:to:through:size:)`, never past `size`) and nothing reads it.
        let buffer = unsafe UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16384)
        defer { unsafe buffer.deallocate() }
        reading: for url in urls where !state.withLock({ $0.done.contains(url) }) {
            // SAFETY: open reads the NUL-terminated copy of the path Swift makes for the call.
            // concurrency-allow: a files-lane item or the library-load thread (Task.detached in CEFRuntime.start/preload), never the main thread
            let descriptor = unsafe blockingOpen(url.path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else {
                state.withLock { _ = $0.done.insert(url) }
                continue
            }
            defer { close(descriptor) }
            var info = stat()
            // SAFETY: fstat writes one `stat` into `info` during the call.
            let length = unsafe fstat(descriptor, &info) == 0 ? Int(info.st_size) : 0
            var step = nextStep(url, length: length, spent: bytes, budget: budget, stop: stop)
            while case .chunk(let offset) = step {
                // SAFETY: `buffer` holds `size` bytes (above).
                bytes += unsafe Self.read(descriptor, from: offset, to: min(offset + Self.chunkBytes, length), through: buffer, size: size)
                step = nextStep(url, length: length, spent: bytes, budget: budget, stop: stop)
            }
            switch step {
            case .chunk: break
            case .fileEnded(let finishedByThisReader): files += finishedByThisReader ? 1 : 0
            case .ended(let ended):
                outcome = ended
                break reading
            }
        }
        let elapsed = clock.now - started
        state.withLock { state in
            var report = state.report ?? Report()
            report.bytes += bytes
            report.files += files
            report.duration += elapsed
            state.report = report
        }
        return (outcome, bytes, elapsed)
    }

    /// What a reader does next with a file.
    nonisolated private enum Step: Sendable {
        /// Read the chunk at this offset (claimed for this reader).
        case chunk(Int)
        /// Every byte of the file is claimed; true for the reader that found the end first.
        case fileEnded(Bool)
        /// The read ends here (``Outcome/stopped`` or ``Outcome/budgetSpent``).
        case ended(Outcome)
    }

    /// The next step for a reader of `url` (`length` bytes) that read `spent` of its `budget`: it ends when `stop`
    /// says so or the budget is spent, else it claims the next chunk no reader claimed. The claim that finds the
    /// end first marks the file done.
    private func nextStep(_ url: URL, length: Int, spent: Int, budget: Int, stop: () -> Bool) -> Step {
        if stop() { return .ended(.stopped) }
        if spent >= budget { return .ended(.budgetSpent) }
        return state.withLock { state in
            let offset = state.claimed[url, default: 0]
            guard offset < length else { return .fileEnded(state.done.insert(url).inserted) }
            state.claimed[url] = offset + Self.chunkBytes
            return .chunk(offset)
        }
    }

    /// Reads bytes `start..<end` of `descriptor` through `buffer` (`size` bytes); returns how many it read.
    private static func read(_ descriptor: Int32, from start: Int, to end: Int, through buffer: UnsafeMutableRawPointer,
                             size: Int) -> Int {
        var offset = start
        while offset < end {
            // SAFETY: pread writes at most min(size, end - offset) <= size bytes into `buffer`, which holds `size`.
            // concurrency-allow: a files-lane item or the library-load thread, never the main thread
            let count = unsafe blockingPread(descriptor, buffer, min(size, end - offset), off_t(offset))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            offset += count
        }
        return offset - start
    }
}
