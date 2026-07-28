import CmuxSimulatorSystem
import Darwin
import Foundation

/// Opens POSIX shared memory through a C bridge that preserves its variadic ABI.
///
/// Swift cannot import the variadic `shm_open` declaration directly.
package func simulatorOpenSharedMemory(
    named name: String,
    flags: Int32,
    permissions: mode_t = S_IRUSR | S_IWUSR
) throws -> Int32 {
    name.withCString {
        cmux_simulator_shm_open($0, flags, UInt16(permissions))
    }
}

package func simulatorFrameSharedMemoryNameIsValid(_ name: String) -> Bool {
    let prefix = "/cmux-sim-frame-"
    guard name.utf8.count == prefix.utf8.count + 12,
          name.hasPrefix(prefix) else { return false }
    return name.utf8.dropFirst(prefix.utf8.count).allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
    }
}

package func simulatorUnlinkFrameSharedMemory(named name: String) {
    guard simulatorFrameSharedMemoryNameIsValid(name) else { return }
    shm_unlink(name)
}
