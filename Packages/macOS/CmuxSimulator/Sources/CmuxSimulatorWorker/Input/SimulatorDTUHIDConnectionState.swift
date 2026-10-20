import Foundation

/// Main-actor availability state updated by the XPC event callback.
@MainActor
final class SimulatorDTUHIDConnectionState {
    private(set) var isAvailable = true

    func markUnavailable() {
        isAvailable = false
    }
}
