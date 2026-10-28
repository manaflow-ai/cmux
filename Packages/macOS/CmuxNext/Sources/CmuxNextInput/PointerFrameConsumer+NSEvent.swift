public import AppKit
public import CmuxNextWakeups
import CmuxNextInputCore

extension PointerFrameConsumer {
    /// Posts a move, drag or scroll to the window's ``FrameInputCoalescer`` (its leading edge goes out
    /// at once, the rest at the window's frame); false, and nothing posted, for any other event type.
    @discardableResult
    public func post(_ event: NSEvent) -> Bool { // perf-hot: 2us pointer-coalesce (every continuous pointer event a view posts)
        guard let type = InputEventType(event.type), PointerCoalescedKind(type) != nil else { return false }
        post(InputEventRecord(event, type: type))
        return true
    }
}
