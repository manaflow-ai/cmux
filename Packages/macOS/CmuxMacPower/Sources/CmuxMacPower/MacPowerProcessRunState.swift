internal import Foundation

typealias MacPowerRunResult = (success: Bool, output: String?)

/// Actor-owned completion state for one spawned Mac power command.
actor MacPowerProcessRunState {
    private var output: Data?
    private var didTerminate = false
    private var exitStatus: Int32?
    private var resumed = false

    init(captureOutput: Bool) {
        output = captureOutput ? nil : Data()
    }

    func recordOutput(_ data: Data) -> MacPowerRunResult? {
        output = data
        return completeIfReady()
    }

    func recordTermination(_ status: Int32) -> MacPowerRunResult? {
        didTerminate = true
        exitStatus = status
        return completeIfReady()
    }

    func claim(_ result: MacPowerRunResult) -> Bool {
        guard !resumed else { return false }
        resumed = true
        return true
    }

    private func completeIfReady() -> MacPowerRunResult? {
        guard !resumed,
              let output,
              didTerminate else {
            return nil
        }
        resumed = true
        return (
            success: exitStatus == 0,
            output: String(data: output, encoding: .utf8)
        )
    }
}
