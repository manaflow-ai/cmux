import Darwin
import Foundation

extension LineTransport {
    /// Offsets (from `data.startIndex`) of every newline at or after `offset`.
    static func newlineOffsets(in data: Data, from offset: Int) -> [Int] {
        data.withUnsafeBytes { raw -> [Int] in
            guard let base = raw.baseAddress, offset < raw.count else { return [] }
            var offsets: [Int] = []
            var position = offset
            while position < raw.count, let hit = memchr(base + position, 0x0A, raw.count - position) {
                let found = base.distance(to: UnsafeRawPointer(hit))
                offsets.append(found)
                position = found + 1
            }
            return offsets
        }
    }
}
