public import CmuxNextCompat
public import CmuxNextWakeups

/// The app process's threads at the first window's first frame, as launch values the startup
/// bench reads (`launch.first_frame_threads*`, scripts/cmux-next/bench-startup.py): every thread, the threads each
/// linked library started (``ThreadRegistry``'s library rows and name spaces), and the threads of a native runtime
/// that no first frame needs.
///
/// Chrome keeps the same rule for its browser process: only the threads the first paint needs run before it, and
/// the rest start from `AfterStartupTaskUtils` (chrome/browser/after_startup_task_utils.cc). Here the one such
/// runtime is iroh-ffi's tokio pool, which only the phone listener starts, from an afterStartup post
/// (`LaunchServicePosts.platform`'s `Mobile.follow`). The app's own Rust library, CCmuxAppFFI, starts no thread on
/// macOS, and libghostty's threads (one renderer and one IO thread per surface, its app's warm-ups) are counted as
/// GhosttyKit's, not as a runtime.
///
/// It reads only Mach thread state (``MachThreads``): one `task_threads` and one `thread_info` per thread.
public struct LaunchThreadCensus: Sendable, Equatable {
    /// The launch value with every thread of the process.
    public static let threadsValue = "launch.first_frame_threads"
    /// The launch value with the threads of ``runtimeLibraries``: 0 is the p08-startup-068 target.
    public static let runtimeThreadsValue = "launch.first_frame_runtime_threads"
    /// The launch value with libghostty's threads.
    public static let ghosttyThreadsValue = "launch.first_frame_ghostty_threads"
    /// The libraries whose threads are a runtime the first frame never needs (``ThreadRegistry/app``'s names).
    public static let runtimeLibraries: Set<String> = ["iroh"]

    /// Every thread of the process.
    public var threads: Int
    /// The threads each linked library started, by its registry name (`GhosttyKit`, `CEF`, `iroh`, ...).
    public var libraries: [String: Int]

    /// The threads of ``runtimeLibraries``.
    public var runtimeThreads: Int {
        libraries.reduce(0) { Self.runtimeLibraries.contains($1.key) ? $0 + $1.value : $0 }
    }

    /// Takes the census right after the first window's first frame, on the cpu lane (never on main), and sends
    /// each of its ``values`` to `record` from there. Only a committed frame takes it
    /// (``StartupScheduler/whenFirstFrameCommitted(_:)``): a reveal-deadline release or a launch that never draws
    /// sends no value, so the bench reads a missing count, not one taken before the frame. Debug and bench builds
    /// only; elsewhere it posts nothing.
    ///
    /// - Parameters:
    ///   - startup: The launch's scheduler: the census waits for its committed first frame.
    ///   - record: Takes each value's name and value (the app passes `LaunchMarkSink.writeValue`, any thread).
    @MainActor
    public static func post(on startup: StartupScheduler, record: @escaping @Sendable (_ name: String, _ value: UInt64) -> Void) {
        #if DEBUG || CMUX_BENCH_HOOKS
        startup.whenFirstFrameCommitted { [weak startup] in
            startup?.post(.afterFirstFrame, "Launch.threadCensus", on: .lane(.cpu, .userVisible)) {
                for value in LaunchThreadCensus.now().values { record(value.name, value.value) }
            }
        }
        #endif
    }

    /// The process's threads now.
    ///
    /// - Parameter registry: Which library owns each thread name (the app's by default).
    public static func now(registry: ThreadRegistry = .app) -> LaunchThreadCensus {
        LaunchThreadCensus(names: MachThreads.withTaskThreads { threads in threads.map { MachThreads.name($0) } }, registry: registry)
    }

    /// The census of threads with `names` (an unnamed thread's name is empty).
    ///
    /// - Parameters:
    ///   - names: One name per live thread.
    ///   - registry: Which library owns each name: a library row first, else a library name space.
    init(names: [String], registry: ThreadRegistry) {
        threads = names.count
        var libraries: [String: Int] = [:]
        for name in names {
            guard let library = registry.declaration(for: name)?.library ?? registry.namespaceLibrary(of: name) else { continue }
            libraries[library, default: 0] += 1
        }
        self.libraries = libraries
    }

    /// The launch values, in a fixed order: every thread, the runtime threads, libghostty's threads.
    public var values: [(name: String, value: UInt64)] {
        [(Self.threadsValue, UInt64(clamping: threads)), (Self.runtimeThreadsValue, UInt64(clamping: runtimeThreads)),
         (Self.ghosttyThreadsValue, UInt64(clamping: libraries["GhosttyKit", default: 0]))]
    }
}
