public import CmuxNextWakeups

/// A page host's replies to its async calls (a page's selection read, a provider's open), applied on
/// the queue of the tab that asked (plans/cmux-next/chrome-parity/p06-scheduler.md, "Posting API" and
/// recipe R-hop): Chrome's `PostTaskAndReplyWithResult` to a frame's task queue
/// (base/task/task_runner.h, third_party/blink/renderer/platform/scheduler/main_thread/frame_scheduler_impl.h).
///
/// The async part runs in a task off the main actor; its result comes back as one task with this
/// host's owner, posted on the tab's ``VisibilityNode`` queue in the `visible` class. A hidden tab's
/// reply waits until the tab shows, and a closed tab's (``close(_:)``) is dropped with its queue. A
/// reply with no tab (a page outside the tab strip) is one `visible` task on the scheduler.
///
/// ```swift
/// let replies = PageTabReplies(owner: "files.page-reply", on: mainWork) { key in nodes.node(ofKey: key) }
/// replies.reply(for: key) { await page?.selectedText() } apply: { text in quote(text) }
/// replies.close(key)  // the tab closed
/// ```
@MainActor
public final class PageTabReplies {
    private let owner: MainTaskOwner
    private let ownerName: String
    private let mainWork: MainWorkScheduler
    private let node: @MainActor (String) -> VisibilityNode?
    private var queues: [String: MainTaskQueue] = [:]

    /// - Parameters:
    ///   - owner: The replies' owner on the board.
    ///   - mainWork: The app's main-thread scheduler.
    ///   - node: Tab `key`'s node; nil when the tab has none (its replies then run as plain posts).
    public init(owner: String, on mainWork: MainWorkScheduler, node: @escaping @MainActor (String) -> VisibilityNode?) {
        self.owner = mainWork.board.owner(owner)
        ownerName = owner
        self.mainWork = mainWork
        self.node = node
    }

    /// Runs `operation` off the main actor, then `apply` with its result on tab `key`'s queue (nil:
    /// no tab). A cancelled task applies nothing.
    ///
    /// - Returns: The task; cancel it to drop the reply.
    @discardableResult
    public func reply<T: Sendable>(for key: String?, file: StaticString = #fileID, line: UInt = #line,
                                   _ operation: @escaping @Sendable () async -> T,
                                   apply: @escaping @MainActor @Sendable (T) -> Void) -> Task<Void, Never> {
        let tabQueue = key.flatMap { self.queue(for: $0) }, mainWork = mainWork, owner = owner
        return Self.start(operation) { value in
            mainWork.postFromAnyThread(.visible, owner: owner, file: file, line: line) {
                guard let tabQueue else { return apply(value) }
                tabQueue.post(file: file, line: line) { apply(value) }
            }
        }
    }

    /// Tab `key` closed: replies still waiting on its queue are dropped.
    public func close(_ key: String) {
        queues[key] = nil
    }

    /// Replies waiting on tab `key`'s queue (held while it is hidden).
    public func pendingCount(for key: String) -> Int {
        queues[key]?.pendingCount ?? 0
    }

    private func queue(for key: String) -> MainTaskQueue? {
        if let held = queues[key] { return held }
        guard let tabNode = node(key) else { return nil }
        let made = tabNode.queue(.visible, owner: ownerName, on: mainWork)
        queues[key] = made
        return made
    }

    /// The async part, in a task that inherits no actor; `deliver` gets its value unless it was cancelled.
    private nonisolated static func start<T: Sendable>(_ operation: @escaping @Sendable () async -> T,
                                                       deliver: @escaping @Sendable (T) -> Void) -> Task<Void, Never> {
        // task-owner: the caller's reply handle; it ends when the operation returns
        Task {
            let value = await operation()
            guard !Task.isCancelled else { return }
            deliver(value)
        }
    }
}
