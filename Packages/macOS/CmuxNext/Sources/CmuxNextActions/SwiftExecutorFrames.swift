internal import Darwin
internal import ObjectiveC
internal import os

/// What the Swift concurrency runtime records about the job running on the current thread, and the
/// one way that record goes bad in cmux (#44060).
///
/// Every frame that runs a Swift job synchronously (`swift_job_run` for a main-queue job,
/// `Task.immediate`, an isolated `deinit` run inline) puts an executor record on the thread's stack,
/// points the runtime's thread slot at it, and restores the slot when it returns. An Objective-C
/// exception that unwinds such a frame and is caught by an older system frame skips the restore:
/// the slot keeps pointing into stack memory that later calls overwrite. The next main-actor
/// isolation check (the one at the entry of every `@MainActor` `@objc` method, like `sendEvent:`)
/// reads that memory as an executor and segfaults in `swift_getObjectType`, minutes after the
/// exception and far from its cause. A live record always lies in a frame that calls the current
/// one, at a higher address than any local here, so a record below the current frame is dead:
/// ``deadRecord()`` proves the state lost before the runtime trips on it.
///
/// ```swift
/// if let dead = SwiftExecutorFrames.deadRecord() { SwiftExecutorFrames.stateLost(at: dead, in: "sendEvent") }
/// ```
public nonisolated struct SwiftExecutorFrames {
    public nonisolated init() {}
    /// libswift_Concurrency's executor-tracking slot: `SWIFT_CONCURRENCY_EXECUTOR_TRACKING_INFO_KEY`
    /// (swift/Threading/ThreadLocalStorage.h) is `__PTK_FRAMEWORK_SWIFT_KEY4` (pthread
    /// tsd_private.h), key 104. A reserved key of the OS runtime: it never moves.
    static let trackingKey = pthread_key_t(104)

    /// The address of the executor record of the job running on this thread, or nil when no Swift
    /// job runs on it.
    public static func activeRecord() -> UInt? {
        let record = UInt(bitPattern: pthread_getspecific(trackingKey))
        return record == 0 ? nil : record
    }

    /// The executor record's address when it lies below this call's own frame, in stack memory no
    /// live frame owns: the frame that set it ended without restoring the slot (an exception unwound
    /// it). Nil when the state is sound. It never reports a live record; it can miss a dead one that
    /// a deeper call chain has covered since.
    @inline(never)
    public static func deadRecord() -> UInt? {
        guard let record = activeRecord() else { return nil }
        var marker = 0
        let frame = withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) }
        return record < frame ? record : nil
    }

    /// Runs `body`, which runs inside a Swift job frame the caller started, and calls `onUnwind` when
    /// an Objective-C exception thrown in `body` is about to be caught outside it, while the throw's
    /// stack still exists. Without `onUnwind` the process ends there (``stateLost(at:in:)``), so the
    /// crash report shows the throw: unwinding on would leave the executor record dead.
    ///
    /// - Parameters:
    ///   - site: Names the frame in the crash log line.
    ///   - onUnwind: Runs instead of ending the process (tests observe the unwind with it).
    ///   - body: The work run inside the job frame.
    /// - Returns: What `body` returns.
    public static func guardingUnwind<R>(_ site: StaticString, onUnwind: (@Sendable () -> Void)? = nil,
                                         _ body: () -> R) -> R {
        let handler = UnwindHandler(site: "\(site)", onUnwind: onUnwind)
        let token = objc_addExceptionHandler(unwindHandler, Unmanaged.passUnretained(handler).toOpaque())
        defer { objc_removeExceptionHandler(token) }
        return withExtendedLifetime(handler) { body() }
    }

    /// Ends the process because the executor record of `site`'s thread is lost: logs a fault (kept in
    /// the unified log, subsystem `com.cmuxterm.app.next`, category `crash`) and aborts, so the crash
    /// report shows where the loss was found instead of a segfault in the runtime later.
    public static func stateLost(at record: UInt?, in site: String) -> Never {
        let address = record.map { "0x" + String($0, radix: 16) } ?? "none"
        Logger(subsystem: "com.cmuxterm.app.next", category: "crash").fault(
            "Swift executor state lost in \(site, privacy: .public): an Objective-C exception unwound a Swift job frame (#44060); executor record \(address, privacy: .public)")
        abort()
    }
}

/// The context of one ``SwiftExecutorFrames/guardingUnwind(_:onUnwind:_:)`` call.
private nonisolated final class UnwindHandler {
    let site: String
    let onUnwind: (@Sendable () -> Void)?

    init(site: String, onUnwind: (@Sendable () -> Void)?) {
        self.site = site
        self.onUnwind = onUnwind
    }
}

/// The Objective-C runtime calls it when an exception thrown inside a guarded frame is caught outside
/// it (`objc_addExceptionHandler`); its first argument is always nil.
private nonisolated let unwindHandler: objc_exception_handler = { _, context in
    guard let context else { return }
    let handler = Unmanaged<UnwindHandler>.fromOpaque(context).takeUnretainedValue()
    guard let onUnwind = handler.onUnwind else {
        SwiftExecutorFrames.stateLost(at: SwiftExecutorFrames.activeRecord(), in: handler.site)
    }
    onUnwind()
}
