import Foundation
import Testing
@testable import CmuxComputerUse

struct ComputerUseLaunchLeaseTests {
    @Test func secondLeaseCannotAcquireTheSameRuntimeLease() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cua-launch-lease-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try ComputerUseLaunchLease(runtimeDirectory: directory)
        let second = try ComputerUseLaunchLease(runtimeDirectory: directory)
        #expect(try first.tryAcquire())
        #expect(try second.tryAcquire() == false)
        first.release()
        #expect(try second.tryAcquire())
    }
}
