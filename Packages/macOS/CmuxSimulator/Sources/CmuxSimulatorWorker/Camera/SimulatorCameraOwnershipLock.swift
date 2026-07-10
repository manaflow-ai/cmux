import Darwin
import Foundation

/// One camera surface ring may own a Simulator UDID across worker processes.
final class SimulatorCameraOwnershipLock: @unchecked Sendable {
    private static let processLock = NSLock()
    nonisolated(unsafe) private static var processOwners: Set<String> = []

    private let key: String
    private let descriptor: Int32

    private init(key: String, descriptor: Int32) {
        self.key = key
        self.descriptor = descriptor
    }

    static func acquire(deviceIdentifier: String) throws -> SimulatorCameraOwnershipLock {
        let key = deviceIdentifier.lowercased()
        let reserved = processLock.withLock { processOwners.insert(key).inserted }
        guard reserved else {
            throw SimulatorWorkerFailure.cameraOwnershipBusy(
                String(
                    localized: "simulator.failure.cameraOwnershipBusy",
                    defaultValue: "Another cmux Simulator pane already owns the camera feed for this device."
                )
            )
        }

        let path = lockFilePath(deviceIdentifier: key)
        let descriptor = path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            _ = processLock.withLock { processOwners.remove(key) }
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                String(
                    localized: "simulator.failure.cameraOwnershipLockUnavailable",
                    defaultValue: "Could not open the Simulator camera ownership lock."
                )
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            _ = processLock.withLock { processOwners.remove(key) }
            throw SimulatorWorkerFailure.cameraOwnershipBusy(
                String(
                    localized: "simulator.failure.cameraOwnershipBusy",
                    defaultValue: "Another cmux Simulator pane already owns the camera feed for this device."
                )
            )
        }
        return SimulatorCameraOwnershipLock(key: key, descriptor: descriptor)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
        _ = Self.processLock.withLock { Self.processOwners.remove(key) }
    }

    nonisolated static func lockFilePath(deviceIdentifier: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in deviceIdentifier.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(
            String(format: "cmux-simulator-camera-%016llx.lock", hash)
        )
    }
}
