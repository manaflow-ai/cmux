import Foundation

// FileHandle callbacks are synchronous Foundation callbacks; this lock guards only this bounded stdout buffer.
final class AutoNamingOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var exceededLimit = false

    func append(_ newData: Data, maxBytes: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !exceededLimit else { return false }
        guard data.count + newData.count <= maxBytes else {
            exceededLimit = true
            data.removeAll(keepingCapacity: false)
            return false
        }
        data.append(newData)
        return true
    }

    func dataIfWithinLimit() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return exceededLimit ? nil : data
    }
}
