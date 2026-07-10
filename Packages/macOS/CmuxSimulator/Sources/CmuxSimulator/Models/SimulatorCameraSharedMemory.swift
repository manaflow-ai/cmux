import Darwin
import Foundation

/// A deterministic camera control-region name shared by the worker and its
/// supervising host. The host can unlink the name after an abrupt worker exit.
package enum SimulatorCameraSharedMemory {
    package static func name(
        deviceIdentifier: String,
        processIdentifier: Int32
    ) -> String {
        let identity = "\(deviceIdentifier.lowercased())\u{0}\(processIdentifier)"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "/cmux-sc-%016llx", hash)
    }

    @discardableResult
    package static func unlink(
        deviceIdentifier: String,
        processIdentifier: Int32
    ) -> Bool {
        Darwin.shm_unlink(name(
            deviceIdentifier: deviceIdentifier,
            processIdentifier: processIdentifier
        )) == 0
    }
}
