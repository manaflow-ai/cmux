import Darwin
import Foundation

/// An unguessable camera frame-region name shared by the worker and its
/// supervising host. The host can unlink the name after an abrupt worker exit.
package struct SimulatorCameraSharedMemory: Sendable {
    package static let tokenEnvironmentKey = "CMUX_SIMULATOR_CAMERA_TOKEN"

    private let deviceIdentifier: String
    private let processIdentifier: Int32
    private let token: String

    package init(
        deviceIdentifier: String,
        processIdentifier: Int32,
        token: String
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.processIdentifier = processIdentifier
        self.token = token
    }

    package var name: String {
        let identity = "\(token)\u{0}\(deviceIdentifier.lowercased())\u{0}\(processIdentifier)"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "/cmux-sc-%016llx", hash)
    }

    @discardableResult
    package func unlink() -> Bool {
        Darwin.shm_unlink(name) == 0
    }
}
