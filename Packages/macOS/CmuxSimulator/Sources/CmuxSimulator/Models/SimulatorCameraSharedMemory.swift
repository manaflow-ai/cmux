import Darwin
import Foundation

/// A deterministic camera control-region name shared by the worker and its
/// supervising host. The host can unlink the name after an abrupt worker exit.
package struct SimulatorCameraSharedMemory: Sendable {
    private let deviceIdentifier: String
    private let processIdentifier: Int32

    package init(
        deviceIdentifier: String,
        processIdentifier: Int32
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.processIdentifier = processIdentifier
    }

    package var name: String {
        let identity = "\(deviceIdentifier.lowercased())\u{0}\(processIdentifier)"
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
