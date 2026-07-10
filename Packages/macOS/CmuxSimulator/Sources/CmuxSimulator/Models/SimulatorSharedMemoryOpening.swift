import Darwin
import Foundation

/// Opens POSIX shared memory through libc's fixed ABI.
///
/// Swift cannot import the variadic `shm_open` declaration directly.
package func simulatorOpenSharedMemory(
    named name: String,
    flags: Int32,
    permissions: mode_t = S_IRUSR | S_IWUSR
) throws -> Int32 {
    typealias Function =
        @convention(c) (
            UnsafePointer<CChar>,
            Int32,
            mode_t
        ) -> Int32
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open") else {
        throw POSIXError(.ENOSYS)
    }
    let function = unsafeBitCast(symbol, to: Function.self)
    return name.withCString { function($0, flags, permissions) }
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
