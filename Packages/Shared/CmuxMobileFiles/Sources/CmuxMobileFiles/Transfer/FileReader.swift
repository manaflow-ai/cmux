import Foundation

/// Reads a staged local file at offsets.
final class FileReader: Sendable {
    let size: UInt64
    private let handle: FileHandle

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    deinit {
        try? handle.close()
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else {
            throw MobileClientError(code: "files.not_found", message: "the local file changed")
        }
        return data
    }
}
