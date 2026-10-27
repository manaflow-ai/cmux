// The AppKit-free half of the input tap (InputSubscription, InputEventRecord, InputEventClasses,
// InputObserving) lives in CmuxNextInputCore; every module that imports CmuxNextInput keeps seeing it.
@_exported public import CmuxNextInputCore
