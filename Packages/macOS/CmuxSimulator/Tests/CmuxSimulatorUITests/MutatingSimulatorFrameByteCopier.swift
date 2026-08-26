import Foundation

@testable import CmuxSimulatorUI

final class MutatingSimulatorFrameByteCopier: SimulatorFrameByteCopying, @unchecked Sendable {
    private let mutation: () -> Void

    init(mutation: @escaping () -> Void) {
        self.mutation = mutation
    }

    func copyBytes(from address: UnsafeRawPointer, count: Int) async -> Data? {
        let data = Data(bytes: address, count: count)
        mutation()
        return data
    }
}
