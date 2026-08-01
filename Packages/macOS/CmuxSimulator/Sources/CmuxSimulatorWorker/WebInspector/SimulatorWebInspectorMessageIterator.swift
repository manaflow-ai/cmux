import Foundation

struct SimulatorWebInspectorMessageIterator: AsyncIteratorProtocol {
    let storage: SimulatorWebInspectorMessageStorage

    mutating func next() async -> Data? {
        await storage.next()
    }
}
