/// The owner of the device's terminal appearance (the app's settings store).
/// Terminal screens read the current value and follow changes while visible.
@MainActor
public protocol TerminalAppearanceProviding: AnyObject {
    var appearance: TerminalAppearance { get }
    /// Every change, starting with the current value; ends when the caller
    /// cancels its iteration.
    func appearanceUpdates() -> AsyncStream<TerminalAppearance>
}
