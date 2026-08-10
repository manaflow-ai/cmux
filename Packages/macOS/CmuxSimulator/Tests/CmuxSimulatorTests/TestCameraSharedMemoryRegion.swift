import Darwin
import Foundation
@testable import CmuxSimulator

let simulatorTestCameraSharedMemoryToken = "cmux-simulator-tests-private-token"

final class TestCameraSharedMemoryRegion {
    private let name: String
    private let descriptor: Int32

    init(deviceIdentifier: String, processIdentifier: Int32) throws {
        name = SimulatorCameraSharedMemory(
            deviceIdentifier: deviceIdentifier,
            processIdentifier: processIdentifier,
            token: simulatorTestCameraSharedMemoryToken
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
    let descriptor = try simulatorOpenSharedMemory(named: name, flags: flags)
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return descriptor
}
