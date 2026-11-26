import Darwin
import Foundation
import UniformTypeIdentifiers

/// Reads explicitly selected local files into a bounded browser upload payload.
///
/// File descriptors and bytes stay on this actor; callers receive only JSON.
/// The socket worker waits for preparation before allowing any DOM mutation.
public actor BrowserInputFileService {
    /// A preparation failure that leaves the page's file selection unchanged.
    public enum Failure: Error, Sendable {
        /// A path is not absolute or the selection contains too many files.
        case invalidSelection
        /// A file cannot be opened, read, or treated as a regular file.
        case unreadableFile
        /// The combined file contents exceed the configured memory budget.
        case tooLarge
        /// The caller cancelled preparation.
        case cancelled
    }

    private let maximumBytes: Int
    private let maximumFiles: Int

    /// Creates a reader with bounded per-request resource use.
    /// - Parameters:
    ///   - maximumBytes: Maximum combined bytes, defaulting to 32 MiB.
    ///   - maximumFiles: Maximum selected files, defaulting to 128.
    public init(maximumBytes: Int = 32 * 1024 * 1024, maximumFiles: Int = 128) {
        self.maximumBytes = max(0, maximumBytes)
        self.maximumFiles = max(0, maximumFiles)
    }

    /// Prepares every file before the browser changes its selection.
    /// - Parameter paths: Absolute paths on the app host; an empty array clears.
    /// - Returns: JSON containing names, MIME types, timestamps and base64 bytes,
    ///   or a failure. The payload never includes the files' directory paths.
    public func prepare(paths: [String]) -> Result<String, Failure> {
        guard paths.count <= maximumFiles,
              paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else {
            return .failure(.invalidSelection)
        }
        var remainingBytes = maximumBytes
        var files: [[String: Any]] = []
        for path in paths {
            guard !Task.isCancelled else { return .failure(.cancelled) }
            switch readFile(path: path, remainingBytes: remainingBytes) {
            case .failure(let failure): return .failure(failure)
            case .success(let file):
                remainingBytes -= file.bytes.count
                let url = URL(fileURLWithPath: path)
                files.append([
                    "name": url.lastPathComponent,
                    "type": UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "",
                    "lastModified": file.modifiedMilliseconds,
                    "base64": file.bytes.base64EncodedString()
                ])
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: files),
              let json = String(data: data, encoding: .utf8) else {
            return .failure(.unreadableFile)
        }
        return .success(json)
    }

    private func readFile(
        path: String,
        remainingBytes: Int
    ) -> Result<(bytes: Data, modifiedMilliseconds: Double), Failure> {
        // O_NONBLOCK prevents a FIFO from blocking before fstat can reject it.
        // Validate the opened descriptor, avoiding a path-stat/open race.
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .failure(.unreadableFile) }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            return .failure(.unreadableFile)
        }
        guard metadata.st_size <= remainingBytes else { return .failure(.tooLarge) }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            guard !Task.isCancelled else { return .failure(.cancelled) }
            let available = remainingBytes - bytes.count
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, available < raw.count ? available + 1 : raw.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(.unreadableFile)
            }
            guard count <= remainingBytes - bytes.count else { return .failure(.tooLarge) }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        let modifiedMilliseconds = Double(metadata.st_mtimespec.tv_sec) * 1000
            + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000
        return .success((bytes, modifiedMilliseconds))
    }
}
