internal import Darwin
internal import Foundation
internal import ObjectiveC
internal import os

/// What the Swift concurrency runtime records about the job running on the current thread, and the
/// one way that record goes bad in cmux (#44060, #44185).
///
/// Every frame that runs a Swift job synchronously (`swift_job_run` for a main-queue job,
/// `Task.immediate`, an isolated `deinit` run inline) puts an executor record on the thread's stack,
/// points the runtime's thread slots at it and at its task, and restores both slots when it returns.
/// An Objective-C exception that unwinds such a frame and is caught by an older system frame skips
/// the restore: the slot keeps pointing into stack memory that later calls overwrite. The next
/// main-actor isolation check (the one at the entry of every `@MainActor` `@objc` method, like
/// `sendEvent:`) reads that memory as an executor and segfaults in `swift_getObjectType`, minutes
/// after the exception and far from its cause. A live record always lies in a frame that calls the
/// current one, at a higher address than any local here, so a record below the current frame is
/// dead: ``deadRecord()`` proves the state lost before the runtime trips on it.
///
/// The process recovers in two places instead of crashing:
/// - ``guardingUnwind(_:restoring:onUnwind:_:)`` puts back the slots the job frame would have
///   restored, at the moment the exception leaves the frame, and logs the throw's stack.
/// - ``recoverDeadRecord(in:)`` clears dead slots where no job can be running (an event dispatch
///   from the run loop), for exceptions that unwind a job no guard covers.
///
/// ```swift
/// if let dead = SwiftExecutorFrames.recoverDeadRecord(in: "sendEvent") { _ = dead }
/// ```
public nonisolated struct SwiftExecutorFrames {
    public nonisolated init() {}
    /// libswift_Concurrency's executor-tracking slot: `SWIFT_CONCURRENCY_EXECUTOR_TRACKING_INFO_KEY`
    /// (swift/Threading/ThreadLocalStorage.h) is `__PTK_FRAMEWORK_SWIFT_KEY4` (pthread
    /// tsd_private.h), key 104. A reserved key of the OS runtime: it never moves.
    static let trackingKey = pthread_key_t(104)

    /// libswift_Concurrency's current-task slot: `SWIFT_CONCURRENCY_TASK_KEY` is
    /// `__PTK_FRAMEWORK_SWIFT_KEY3`, key 103. A job frame sets and restores it with the record.
    static let taskKey = pthread_key_t(103)

    /// Both runtime slots of one thread at one moment.
    public struct Slots: Sendable, Equatable {
        /// The executor record's address, 0 when no job runs.
        public let record: UInt
        /// The current task's address, 0 when no task is current.
        public let task: UInt

        /// The slots of the calling thread now.
        public static func current() -> Slots {
            Slots(record: UInt(bitPattern: pthread_getspecific(trackingKey)),
                  task: UInt(bitPattern: pthread_getspecific(taskKey)))
        }

        /// Writes these values into the calling thread's slots.
        func install() {
            pthread_setspecific(trackingKey, UnsafeRawPointer(bitPattern: record))
            pthread_setspecific(taskKey, UnsafeRawPointer(bitPattern: task))
        }

        init(record: UInt, task: UInt) {
            self.record = record
            self.task = task
        }
    }

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

    /// Clears a dead executor record and the stale task beside it, logs a fault, and returns the
    /// dead record's address; returns nil and changes nothing when the state is sound.
    ///
    /// Call it only where no Swift job can be running on the thread (an event dispatch from the
    /// run loop): there the sound value of both slots is empty.
    /// - Parameter site: Names the caller in the log line.
    /// - Returns: The dead record's address, or nil.
    @inline(never)
    @discardableResult
    public static func recoverDeadRecord(in site: StaticString) -> UInt? {
        guard let dead = deadRecord() else { return nil }
        Slots(record: 0, task: 0).install()
        let name = "\(site)"
        log.fault(
            "Swift executor record lost before \(name, privacy: .public): an Objective-C exception unwound a Swift job frame that no guard covers (#44060); cleared dead record 0x\(String(dead, radix: 16), privacy: .public)")
        return dead
    }

    /// Runs `body`, which runs inside a Swift job frame the caller started from `outer`, and repairs
    /// the thread when an Objective-C exception thrown in `body` is caught outside it.
    ///
    /// At the moment the exception leaves `body` (phase 2 of the unwind, before the catch runs) it
    /// puts `outer` back into the runtime's slots, which is what the job frame would have done on a
    /// normal return, logs the throw's stack (the throwing frames still exist then) as a fault, and
    /// calls `onUnwind`. The exception then goes on to its catch.
    ///
    /// - Parameters:
    ///   - site: Names the frame in the log line.
    ///   - outer: The slots read just before the job frame started (``Slots/current()``).
    ///   - onUnwind: Runs after the repair (tests observe the unwind with it).
    ///   - body: The work run inside the job frame.
    /// - Returns: What `body` returns.
    public static func guardingUnwind<R>(_ site: StaticString, restoring outer: Slots,
                                         onUnwind: (@Sendable () -> Void)? = nil, _ body: () -> R) -> R {
        let handler = UnwindHandler(site: "\(site)", outer: outer, onUnwind: onUnwind)
        let token = objc_addExceptionHandler(unwindHandler, Unmanaged.passUnretained(handler).toOpaque())
        defer { objc_removeExceptionHandler(token) }
        return withExtendedLifetime(handler) { body() }
    }

    static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "crash")
}

/// The context of one ``SwiftExecutorFrames/guardingUnwind(_:restoring:onUnwind:_:)`` call.
nonisolated final class UnwindHandler {
    let site: String
    let outer: SwiftExecutorFrames.Slots
    let onUnwind: (@Sendable () -> Void)?

    init(site: String, outer: SwiftExecutorFrames.Slots, onUnwind: (@Sendable () -> Void)?) {
        self.site = site
        self.outer = outer
        self.onUnwind = onUnwind
    }

    /// Repairs the slots after an exception left the guarded frame, and records where it came from.
    func unwound() {
        let lost = SwiftExecutorFrames.Slots.current()
        outer.install()
        let stack = Thread.callStackSymbols.prefix(48).joined(separator: "\n")
        SwiftExecutorFrames.log.fault(
            "Objective-C exception unwound the Swift job frame of \(self.site, privacy: .public) (#44060); executor record 0x\(String(lost.record, radix: 16), privacy: .public) restored to 0x\(String(self.outer.record, radix: 16), privacy: .public). Throw stack:\n\(stack, privacy: .public)")
        onUnwind?()
    }
}

/// The Objective-C runtime calls it when an exception thrown inside a guarded frame is caught outside
/// it (`objc_addExceptionHandler`); its first argument is always nil.
private nonisolated let unwindHandler: objc_exception_handler = { _, context in
    guard let context else { return }
    Unmanaged<UnwindHandler>.fromOpaque(context).takeUnretainedValue().unwound()
}
