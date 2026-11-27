import Darwin
import Foundation

/// One camera surface ring may own a Simulator UDID across worker processes.
// SAFETY: ownership is represented by an immutable kernel file descriptor;
// `flock` serializes acquisition and deinitialization is the only mutation.
final class SimulatorCameraOwnershipLock: @unchecked Sendable {
    private let descriptor: Int32

    init(deviceIdentifier: String) throws {
        let key = deviceIdentifier.lowercased()
        let path = simulatorCameraLockFilePath(deviceIdentifier: key)
        let descriptor = path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                String(
                    localized: "simulator.failure.cameraOwnershipLockUnavailable",
                    defaultValue: "Could not open the Simulator camera ownership lock."
                )
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw SimulatorWorkerFailure.cameraOwnershipBusy(
                String(
                    localized: "simulator.failure.cameraOwnershipBusy",
                    defaultValue: "Another cmux Simulator pane already owns the camera feed for this device."
                )
            )
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

private func simulatorCameraLockFilePath(deviceIdentifier: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in deviceIdentifier.lowercased().utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    return (NSTemporaryDirectory() as NSString).appendingPathComponent(
        String(format: "cmux-simulator-camera-%016llx.lock", hash)
    )
}
