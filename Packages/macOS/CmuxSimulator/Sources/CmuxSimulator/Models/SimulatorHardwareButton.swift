/// A hardware or system button exposed by Apple Simulator devices.
public enum SimulatorHardwareButton: String, Codable, CaseIterable, Sendable {
    /// The classic Home button.
    case home
    /// The home-indicator swipe gesture.
    case swipeHome
    /// The multitasking switcher gesture.
    case appSwitcher
    /// The lock or sleep button.
    case lock
    /// A long side-button press that invokes Siri.
    case siri
    /// The side button.
    case sideButton
    /// The power button described by DeviceKit.
    case power
    /// The volume-up button.
    case volumeUp
    /// The volume-down button.
    case volumeDown
    /// The configurable Action button.
    case action
    /// The Apple Watch side button.
    case watchSideButton
}
