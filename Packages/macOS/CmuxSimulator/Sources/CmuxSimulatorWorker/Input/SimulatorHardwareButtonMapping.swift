import CmuxSimulator

enum SimulatorHardwareButtonMapping: Equatable, Sendable {
    case legacy(eventSource: Int32)
    case arbitrary(page: UInt32, usage: UInt32)
    case swipeHome
    case appSwitcher

    init(_ button: SimulatorHardwareButton) {
        switch button {
        case .home:
            self = .legacy(eventSource: 0)
        case .swipeHome:
            self = .swipeHome
        case .appSwitcher:
            self = .appSwitcher
        case .lock:
            self = .legacy(eventSource: 1)
        case .siri:
            self = .legacy(eventSource: 0x400002)
        case .sideButton:
            self = .legacy(eventSource: 0x0BB8)
        case .power:
            self = .arbitrary(page: 0x0C, usage: 0x30)
        case .volumeUp:
            self = .arbitrary(page: 0x0C, usage: 0xE9)
        case .volumeDown:
            self = .arbitrary(page: 0x0C, usage: 0xEA)
        case .action:
            self = .arbitrary(page: 0x0B, usage: 0x2D)
        case .watchSideButton:
            self = .arbitrary(page: 0x0C, usage: 0x95)
        }
    }
}
