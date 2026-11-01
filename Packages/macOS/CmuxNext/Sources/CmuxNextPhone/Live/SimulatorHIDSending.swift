public import CoreGraphics

/// Sends touches, keys and buttons into a booted iOS simulator and reports
/// its screen size. ``SimulatorKitHID`` is the real one (SimulatorKit's HID
/// services); tests pass a fake.
public protocol SimulatorHIDSending: Sendable {
    /// The screen of the simulator `udid` in points, in its current orientation.
    func screenSize(of udid: String) async throws -> CGSize
    /// Sends each touch at its offset from the first.
    func send(touches: [PhoneTouch], to udid: String) async throws
    /// Presses each key in turn, with its modifiers held around it.
    func send(keys: [PhoneKeyStroke], to udid: String) async throws
    /// Presses and releases one consumer-page or other HID button.
    func press(page: UInt32, usage: UInt32, on udid: String) async throws
    /// Shows or hides the simulator's software keyboard (Simulator's I/O > Keyboard > Toggle Software Keyboard).
    func toggleSoftwareKeyboard(on udid: String) async throws
}

extension SimulatorHIDSending {
    public func toggleSoftwareKeyboard(on udid: String) async throws {
        throw PhoneError.unsupported(mode: .simulator, what: "the software keyboard")
    }
}
