public import CmuxNextTrace

/// `Task.detached` with a stated ``WorkPriority`` and its post site, traced from the post to the run: Chrome's
/// `PostTask(FROM_HERE, ...)`, whose `base::Location` names the post and whose `TaskAnnotator` draws a flow from the
/// post to the run (base/location.h, base/task/common/task_annotator.cc).
///
/// While the `task` trace category records, the post writes a ``TaskTrace`` `task.post` flow-out named by the
/// caller's `#fileID` and `#line`, and the run opens a `task.run` async slice with the pool lane, the priority and
/// the time the task waited for the pool, ends the flow in it, and closes it when the operation returns. The slice is
/// AB/AE because a task can resume on another thread (``TaskTrace/Ticket/beginAsyncRun(priority:)``). While the
/// category is off, a post costs one relaxed load more than `Task.detached` and the task runs the operation as is.
///
/// The priority has no default: every detached task says how much a person waits for it
/// (plans/cmux-next/PATTERNS.md P14, Chrome's `base::TaskPriority`). Work that may block (file I/O, a process wait,
/// a sync C call) belongs on ``BackgroundWork``'s lanes, not on the cooperative pool.
///
/// ```swift
/// TracedTask.detached(priority: .bestEffort) { await sweep(root) }
/// let snapshot = await TracedTask.detached(priority: .userVisible) { await source.read() }.value
/// ```
public struct TracedTask: Sendable {
    /// Where the post and run records go.
    public let trace: TaskTrace

    /// Tasks traced through `trace` (tests inject a runtime with its own ring).
    public init(trace: TaskTrace) {
        self.trace = trace
    }

    /// Runs `operation` as a detached task at `priority`, traced into the process's ``CmuxNextTrace/TraceRuntime/shared``.
    ///
    /// - Parameters:
    ///   - priority: How much a person waits for the result.
    ///   - file: The post site's `#fileID` (leave the default).
    ///   - line: The post site's `#line` (leave the default).
    ///   - operation: The work.
    /// - Returns: The task.
    @discardableResult
    public static func detached<Success: Sendable>(
        priority: WorkPriority, file: StaticString = #fileID, line: UInt = #line,
        operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never> {
        TracedTask(trace: TaskTrace(runtime: .shared)).detached(priority: priority, file: file, line: line, operation: operation)
    }

    /// Runs the throwing `operation` as a detached task at `priority`, traced into the process's
    /// ``CmuxNextTrace/TraceRuntime/shared``.
    ///
    /// - Parameters:
    ///   - priority: How much a person waits for the result.
    ///   - file: The post site's `#fileID` (leave the default).
    ///   - line: The post site's `#line` (leave the default).
    ///   - operation: The work.
    /// - Returns: The task; its value rethrows what `operation` threw.
    @discardableResult
    public static func detached<Success: Sendable>(
        priority: WorkPriority, file: StaticString = #fileID, line: UInt = #line,
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, any Error> {
        TracedTask(trace: TaskTrace(runtime: .shared)).detached(priority: priority, file: file, line: line, operation: operation)
    }

    /// Runs `operation` as a detached task at `priority`, traced through ``trace``.
    ///
    /// - Parameters:
    ///   - priority: How much a person waits for the result.
    ///   - file: The post site's `#fileID` (leave the default).
    ///   - line: The post site's `#line` (leave the default).
    ///   - operation: The work.
    /// - Returns: The task.
    @discardableResult
    public func detached<Success: Sendable>(
        priority: WorkPriority, file: StaticString = #fileID, line: UInt = #line,
        operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never> {
        let ticket = trace.post(fileID: file, line: line, lane: .pool)
        guard ticket.isTraced else { return Task.detached(priority: priority.taskPriority, operation: operation) }
        let code = Self.code(priority)
        return Task.detached(priority: priority.taskPriority) {
            let run = ticket.beginAsyncRun(priority: code)
            defer { run.end() }
            return await operation()
        }
    }

    /// Runs the throwing `operation` as a detached task at `priority`, traced through ``trace``.
    ///
    /// - Parameters:
    ///   - priority: How much a person waits for the result.
    ///   - file: The post site's `#fileID` (leave the default).
    ///   - line: The post site's `#line` (leave the default).
    ///   - operation: The work.
    /// - Returns: The task; its value rethrows what `operation` threw.
    @discardableResult
    public func detached<Success: Sendable>(
        priority: WorkPriority, file: StaticString = #fileID, line: UInt = #line,
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, any Error> {
        let ticket = trace.post(fileID: file, line: line, lane: .pool)
        guard ticket.isTraced else { return Task.detached(priority: priority.taskPriority, operation: operation) }
        let code = Self.code(priority)
        return Task.detached(priority: priority.taskPriority) {
            let run = ticket.beginAsyncRun(priority: code)
            defer { run.end() }
            return try await operation()
        }
    }

    /// The `task.run` priority code of `priority`: its `rawValue`, as a lane item's.
    static func code(_ priority: WorkPriority) -> UInt8 {
        UInt8(truncatingIfNeeded: priority.rawValue)
    }
}
