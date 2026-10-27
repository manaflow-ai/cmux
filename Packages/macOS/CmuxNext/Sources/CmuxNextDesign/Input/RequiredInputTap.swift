import CmuxNextInput
import os

private let inputTapLog = Logger(subsystem: "com.cmuxterm.app.next", category: "input-tap")

/// `tap`, or nil with a fault in the log. An owner with no tap hears none of the clicks and keys
/// that close it (the composition root did not give it the app's tap), which must show in the log,
/// not pass in silence.
func requiredInputTap(_ tap: InputEventTap?, owner: String) -> InputEventTap? {
    if tap == nil { inputTapLog.fault("\(owner, privacy: .public) has no input tap: it hears no dismissal") }
    return tap
}
