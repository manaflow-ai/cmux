/// One key press (down then up) on the simulator's hardware keyboard: a USB
/// HID keyboard usage with the modifiers held around it.
public struct PhoneKeyStroke: Sendable, Hashable {
    public var usage: UInt32
    public var shift: Bool
    public var command: Bool

    public init(usage: UInt32, shift: Bool = false, command: Bool = false) {
        self.usage = usage
        self.shift = shift
        self.command = command
    }
}
