internal import Dispatch
internal import Foundation

/// One dedicated serial execution context for drawable acquisition and Metal submission.
///
/// `CAMetalLayer.nextDrawable()` can block. Keeping it on this queue prevents it
/// from occupying AppKit's main actor or a cooperative Swift concurrency
/// executor. `TerminalRenderMetalBlitter` admits work through a single-drain
/// mailbox, so this queue never receives one work item per arriving frame.
final class TerminalRenderMetalExecutor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let specificKey = DispatchSpecificKey<UInt8>()
    private let specificValue: UInt8 = 1

    init(label: String = "com.cmux.terminal-render-compositor.metal") {
        self.queue = DispatchQueue(
            label: label,
            qos: .userInteractive,
            autoreleaseFrequency: .workItem
        )
        queue.setSpecific(key: specificKey, value: specificValue)
    }

    var isCurrentExecutor: Bool {
        DispatchQueue.getSpecific(key: specificKey) == specificValue
    }

    func enqueue(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }
}
