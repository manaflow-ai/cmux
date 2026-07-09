import Foundation

final class JSONLLineReader {
    private let handle: FileHandle
    private var buffer: Data
    private var reachedEOF: Bool

    init(url: URL) throws {
        self.handle = try FileHandle(forReadingFrom: url)
        self.buffer = Data()
        self.reachedEOF = false
    }

    func nextLine() throws -> String? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 10) {
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(...newlineIndex)
                return String(data: lineData, encoding: .utf8) ?? ""
            }
            guard !reachedEOF else {
                guard !buffer.isEmpty else {
                    return nil
                }
                let lineData = buffer
                buffer.removeAll(keepingCapacity: true)
                return String(data: lineData, encoding: .utf8) ?? ""
            }
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty {
                reachedEOF = true
            } else {
                buffer.append(chunk)
            }
        }
    }

    func close() {
        try? handle.close()
    }
}
