import Foundation

/// The two macOS grants read from the standalone Computer Use daemon.
struct ComputerUsePermissionStatus: Equatable, Sendable {
    var accessibility: Bool
    var screenRecording: Bool

    static let missing = ComputerUsePermissionStatus(
        accessibility: false,
        screenRecording: false
    )
}
