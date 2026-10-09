import CmuxBrowserStream

/// One phone attached to one booted simulator: its encoded frames and the
/// input it accepts. The app implements it (ScreenCaptureKit on the
/// simulator window, SimulatorKit HID); tests use a fake.
public protocol SimulatorAttachment: Sendable {
    var screen: SimulatorScreen { get async }
    var video: any BrowserVideoSource { get }
    func touch(_ touch: SimulatorTouch) async
    /// Committed text (software keyboard, IME).
    func text(_ text: String) async
    /// A hardware key, by DOM code.
    func key(_ event: RbKeyEvent) async
    func pasteboard(_ text: String) async
    /// Ends with the device (shutdown, crash); the last element.
    func ended() async -> AsyncStream<String>
    func detach() async
}
