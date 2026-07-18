import CmuxSimulator

/// Keeps the private orientation dialects used by PurpleWorkspace and SimulatorKit
/// from leaking into cmux's logical orientation model.
enum SimulatorNativeOrientationCodec {
    static func purpleWorkspaceRawValue(for orientation: SimulatorOrientation) -> UInt32 {
        switch orientation {
        case .portrait: 1
        case .portraitUpsideDown: 2
        case .landscapeRight: 3
        case .landscapeLeft: 4
        }
    }

    static func screenOrientation(rawValue: UInt32) -> SimulatorOrientation? {
        switch rawValue {
        case 1: .portrait
        case 2: .portraitUpsideDown
        case 3: .landscapeLeft
        case 4: .landscapeRight
        default: nil
        }
    }
}
