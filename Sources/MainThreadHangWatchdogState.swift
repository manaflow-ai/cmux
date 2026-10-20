import Foundation

/// Pure starvation-detection state used by ``MainThreadHangWatchdog``.
struct MainThreadHangWatchdogState {
    let stallThreshold: TimeInterval
    private(set) var lastHeartbeat: TimeInterval?
    private var capturedCurrentStall = false

    init(stallThreshold: TimeInterval) {
        self.stallThreshold = stallThreshold
    }

    mutating func recordHeartbeat(at timestamp: TimeInterval) {
        lastHeartbeat = timestamp
        capturedCurrentStall = false
    }

    mutating func shouldCapture(at timestamp: TimeInterval) -> Bool {
        guard let lastHeartbeat,
              timestamp - lastHeartbeat >= stallThreshold,
              !capturedCurrentStall else {
            return false
        }
        capturedCurrentStall = true
        return true
    }
}
