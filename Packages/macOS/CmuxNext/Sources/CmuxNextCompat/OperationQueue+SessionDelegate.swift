public import Foundation

extension OperationQueue {
    /// A named serial queue for one `URLSession`'s delegate calls and completions, at `qos`. Pass it as the
    /// session's `delegateQueue:` instead of nil, with which the session makes an unnamed serial queue at the
    /// default QoS: work nobody waits for then competes with typing, and a person's request waits behind it
    /// (plans/cmux-next/PATTERNS.md P14; Chrome names every thread and sets its type, base/threading/platform_thread.h).
    /// The label is listed in plans/cmux-next/threading-model.md.
    ///
    /// - Parameters:
    ///   - name: The queue's label.
    ///   - qos: How much a person waits for the session's answers: `.userInitiated` or `.utility`.
    /// - Returns: A queue that runs one operation at a time.
    nonisolated public static func sessionDelegate(_ name: String, qos: QualityOfService) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = name
        queue.qualityOfService = qos
        queue.maxConcurrentOperationCount = 1
        return queue
    }
}
