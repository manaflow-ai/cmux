import Darwin
import Foundation
@testable import CmuxSimulator

final class TestCameraSharedMemoryRegion {
    private let name: String
    private let descriptor: Int32

    init(deviceIdentifier: String, processIdentifier: Int32) throws {
        name = SimulatorCameraSharedMemory(
            deviceIdentifier: deviceIdentifier,
            processIdentifier: processIdentifier
        ).name
        _ = Darwin.shm_unlink(name)
        descriptor = try openTestCameraSharedMemory(name: name, flags: O_CREAT | O_EXCL | O_RDWR)
        guard ftruncate(descriptor, 1) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            _ = Darwin.shm_unlink(name)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    deinit {
        Darwin.close(descriptor)
        _ = Darwin.shm_unlink(name)
    }

    func exists() -> Bool {
        guard let descriptor = try? openTestCameraSharedMemory(name: name, flags: O_RDWR)
        else { return false }
        Darwin.close(descriptor)
        return true
    }
}

private func openTestCameraSharedMemory(name: String, flags: Int32) throws -> Int32 {
    typealias Function = @convention(c) (
        UnsafePointer<CChar>,
        Int32,
        mode_t
    ) -> Int32
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open") else {
        throw POSIXError(.ENOSYS)
    }
    let function = unsafeBitCast(symbol, to: Function.self)
    let descriptor = name.withCString {
        function($0, flags, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return descriptor
}
