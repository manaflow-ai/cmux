import Foundation

/// Reads and checks untrusted snapshot bytes before schema probing or decoding.
/// Trusted startup loads and exports deliberately bypass these import limits.
struct SessionSnapshotImportReader {
    func read(fileURL: URL) -> Result<Data, SessionSnapshotImportError> {
        switch readRegularFile(atPath: fileURL.path, maximumBytes: maximumBytes) {
        case .data(let data):
            return jsonIsWithinDecodeLimits(data)
                ? .success(data) : .failure(.resourceLimitExceeded(fileURL))
        case .notRegular:
            return .failure(.notASessionSnapshot(fileURL))
        case .tooLarge:
            return .failure(.resourceLimitExceeded(fileURL))
        case .unreadable:
            return .failure(.unreadable(fileURL))
        }
    }

    private enum BoundedFileRead {
        case data(Data)
        case notRegular
        case tooLarge
        case unreadable
    }

    /// Reads a regular file of at most `maximumBytes`. A FIFO or device node
    /// would block the reader forever and an unbounded file would be read
    /// whole into memory, so the file is opened non-blocking and its type
    /// and size are checked on the same descriptor that is read (no window
    /// for a symlink to be re-pointed between the check and the read).
    private func readRegularFile(atPath path: String, maximumBytes: Int64) -> BoundedFileRead {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return .unreadable }
        guard (status.st_mode & S_IFMT) == S_IFREG else { return .notRegular }
        guard Int64(status.st_size) <= maximumBytes else { return .tooLarge }
        do {
            // The file can grow after fstat (autosave/import races). Never
            // call readToEnd on an untrusted path: one bounded read keeps the
            // post-check allocation capped as well.
            let data = try handle.read(upToCount: Int(maximumBytes) + 1) ?? Data()
            guard Int64(data.count) <= maximumBytes else { return .tooLarge }
            return .data(data)
        } catch {
            return .unreadable
        }
    }

    /// Maximum input size admitted before any JSON decoder runs.
    let maximumBytes: Int64 = 256 * 1024 * 1024

    /// Lexical limits applied to an imported file before Foundation
    /// materializes the Codable graph, so an arbitrary file can't build
    /// millions of objects. Only imports are scanned: real snapshots run about
    /// 110-345 tokens per panel, so a large own session can exceed these and
    /// must still load for the restore budget to trim. String length is not
    /// limited: the file size already bounds it, and the app's own snapshot
    /// may legitimately hold a large draft or scrollback string.
    private let maximumJSONNesting = 512
    private let maximumJSONStructuralTokens = 1_000_000

    private func jsonIsWithinDecodeLimits(_ data: Data) -> Bool {
        var nesting = 0
        var structuralTokens = 0
        var inString = false
        var escaped = false
        var expectedContinuationBytes = 0
        var minimumContinuationByte: UInt8 = 0x80
        var maximumContinuationByte: UInt8 = 0xBF
        for byte in data {
            if expectedContinuationBytes > 0 {
                guard byte >= minimumContinuationByte, byte <= maximumContinuationByte else {
                    return false
                }
                expectedContinuationBytes -= 1
                minimumContinuationByte = 0x80
                maximumContinuationByte = 0xBF
                continue
            }
            switch byte {
            case 0x00...0x7F:
                break
            case 0xC2...0xDF:
                expectedContinuationBytes = 1
            case 0xE0:
                expectedContinuationBytes = 2
                minimumContinuationByte = 0xA0
            case 0xE1...0xEC, 0xEE...0xEF:
                expectedContinuationBytes = 2
            case 0xED:
                expectedContinuationBytes = 2
                maximumContinuationByte = 0x9F
            case 0xF0:
                expectedContinuationBytes = 3
                minimumContinuationByte = 0x90
            case 0xF1...0xF3:
                expectedContinuationBytes = 3
            case 0xF4:
                expectedContinuationBytes = 3
                maximumContinuationByte = 0x8F
            default:
                // Reject UTF-16/32, invalid UTF-8, and other encodings before
                // the byte scanner can mistake a low byte for JSON syntax.
                return false
            }
            if byte < 0x20,
               byte != 0x09, byte != 0x0A, byte != 0x0D, byte != 0x20 {
                return false
            }
            if inString {
                if escaped {
                    escaped = false
                } else if byte < 0x20 {
                    return false
                } else if byte == 92 { // backslash
                    escaped = true
                } else if byte == 34 { // quote
                    inString = false
                }
                continue
            }
            switch byte {
            case 34: // quote
                inString = true
            case 91, 123: // [ or {
                structuralTokens += 1
                nesting += 1
                if nesting > maximumJSONNesting { return false }
            case 93, 125: // ] or }
                structuralTokens += 1
                nesting -= 1
                if nesting < 0 { return false }
            case 58, 44: // : or ,
                structuralTokens += 1
            default:
                break
            }
            if structuralTokens > maximumJSONStructuralTokens { return false }
        }
        guard expectedContinuationBytes == 0, !inString, nesting == 0 else {
            return false
        }
        return true
    }

}
