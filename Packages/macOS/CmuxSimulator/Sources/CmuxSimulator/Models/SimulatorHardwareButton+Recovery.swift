extension SimulatorHardwareButton {
    /// Raw HID usage whose up phase safely releases a physical button after a
    /// worker dies during a convenience press. Gesture-only actions return nil.
    public var recoveryHIDUsage: SimulatorHIDButtonUsage? {
        switch self {
        case .home:
            SimulatorHIDButtonUsage(page: 0x0C, usage: 0x40)
        case .lock, .sideButton, .power:
            SimulatorHIDButtonUsage(page: 0x0C, usage: 0x30)
        case .siri:
            SimulatorHIDButtonUsage(page: 0x0C, usage: 0xCF)
        case .volumeUp:
            SimulatorHIDButtonUsage(page: 0x0C, usage: 0xE9)
        case .volumeDown:
            SimulatorHIDButtonUsage(page: 0x0C, usage: 0xEA)
        case .action:
            SimulatorHIDButtonUsage(page: 0x0B, usage: 0x2D)
        case .watchSideButton:
            SimulatorHIDButtonUsage(page: 0x0C, usage: 0x95)
        case .swipeHome, .appSwitcher:
            nil
        }
    }
}
