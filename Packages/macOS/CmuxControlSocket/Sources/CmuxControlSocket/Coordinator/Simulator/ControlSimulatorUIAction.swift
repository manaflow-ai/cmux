/// A semantic Simulator action driven by refs or named presets.
public enum ControlSimulatorUIAction: Sendable, Equatable {
    /// Taps one current element reference.
    case tap(
        elementRef: String,
        preDelayMilliseconds: Int,
        postDelayMilliseconds: Int
    )
    /// Sends explicit touch phases to one current element reference.
    case touch(
        elementRef: String,
        down: Bool,
        up: Bool,
        delayMilliseconds: Int
    )
    /// Swipes within one current element reference.
    case swipe(
        elementRef: String,
        direction: String,
        durationMilliseconds: Int,
        distance: Double,
        steps: Int,
        preDelayMilliseconds: Int,
        postDelayMilliseconds: Int
    )
    /// Drags from one current element reference.
    case drag(
        elementRef: String,
        direction: String,
        durationMilliseconds: Int,
        distance: Double,
        steps: Int,
        preDelayMilliseconds: Int,
        postDelayMilliseconds: Int
    )
    /// Holds a touch on one current element reference.
    case longPress(elementRef: String, durationMilliseconds: Int)
    /// Focuses one current element reference and types text.
    case typeText(elementRef: String, text: String, replaceExisting: Bool)
    /// Presses one USB HID key usage.
    case keyPress(keyCode: UInt32, durationMilliseconds: Int)
    /// Presses a bounded sequence of USB HID key usages.
    case keySequence(keyCodes: [UInt32], delayMilliseconds: Int)
    /// Presses or holds one Simulator hardware button.
    case button(button: String, durationMilliseconds: Int?)
    /// Performs one named screen-level gesture.
    case gesturePreset(
        preset: String,
        durationMilliseconds: Int,
        distance: Double,
        steps: Int,
        preDelayMilliseconds: Int,
        postDelayMilliseconds: Int
    )
    /// Performs a bounded sequence of taps resolved from one snapshot.
    case batch(steps: [ControlSimulatorUITapStep])
}
