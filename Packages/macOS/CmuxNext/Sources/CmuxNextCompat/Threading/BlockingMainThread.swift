#if canImport(Darwin)
// blockingOnMainThread() is inlinable and calls pthread_main_np(), so Darwin is a public import here.
public import Darwin
internal import Dispatch
#else
internal import Glibc
#endif

/// Whether the calling thread is the main thread to the blocking detector: Chrome's UI thread, the one thread that
/// must never block. On macOS that is `pthread_main_np()`, the thread that runs the main run loop and the main
/// queue. On Linux the main queue can run without it: `dispatch_main()` (Swift's async `main`, swift-testing) ends
/// the process's main thread and libdispatch runs the main queue on a worker, so the thread that runs the main
/// queue's job counts as well.
@inlinable @inline(__always)
func blockingOnMainThread() -> Bool {
    #if canImport(Darwin)
    pthread_main_np() != 0
    #else
    pthread_main_np() != 0 || runsMainQueue()
    #endif
}

/// The label of the dispatch queue the calling thread runs, as libdispatch's
/// `dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL)` returns it: a NUL-terminated string the queue owns
/// while this thread runs on it, empty for a queue without a label. Swift's Dispatch on Linux marks the C function
/// unavailable, so there it is found once in libdispatch, which exports it; nil when it is not found.
///
/// - Returns: The label, valid while the calling thread runs its queue.
func currentDispatchQueueLabel() -> UnsafePointer<CChar>? {
    #if canImport(Darwin)
    // SAFETY: dispatch_queue_get_label(NULL) only reads the current queue's label pointer.
    unsafe __dispatch_queue_get_label(nil)
    #else
    // SAFETY: libdispatch's dispatch_queue_get_label, called with DISPATCH_CURRENT_QUEUE_LABEL (NULL), only reads the
    // current queue's label pointer.
    unsafe dispatchQueueGetLabel.map { unsafe $0(nil) }
    #endif
}

#if !canImport(Darwin)
/// Whether the calling thread runs a job of the main queue (libdispatch's label `com.apple.main-thread`).
@usableFromInline
func runsMainQueue() -> Bool {
    guard let label = unsafe currentDispatchQueueLabel() else { return false }
    // SAFETY: `label` is the current queue's NUL-terminated label (see currentDispatchQueueLabel), and the literal is
    // a NUL-terminated C string for the call; strcmp reads both only during it.
    return unsafe strcmp(label, "com.apple.main-thread") == 0
}

/// libdispatch's `const char *dispatch_queue_get_label(dispatch_queue_t)`, looked up once in the process's symbols.
private let dispatchQueueGetLabel: (@convention(c) (OpaquePointer?) -> UnsafePointer<CChar>)? = {
    // SAFETY: dlopen(NULL) is the process's own handle, which stays open; the symbol, when found, is libdispatch's
    // exported function with the C signature above.
    unsafe dlsym(dlopen(nil, RTLD_LAZY), "dispatch_queue_get_label").map {
        unsafe unsafeBitCast($0, to: (@convention(c) (OpaquePointer?) -> UnsafePointer<CChar>).self)
    }
}()
#endif
