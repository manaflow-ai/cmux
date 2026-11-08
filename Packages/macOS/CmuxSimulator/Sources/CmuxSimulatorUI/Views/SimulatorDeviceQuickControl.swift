import CmuxSimulator

enum SimulatorDeviceQuickControl: CaseIterable, Equatable {
    case home
    case screenshot
    case rotate
    case pointerCapture
    case keyboardCapture
}

func simulatorAvailableDeviceQuickControls(
    for family: SimulatorDeviceFamily?
) -> [SimulatorDeviceQuickControl] {
    switch family {
    case .iPad:
        [.home, .screenshot, .rotate, .pointerCapture, .keyboardCapture]
    case .iPhone:
        [.home, .screenshot, .rotate]
    default:
        []
    }
}
