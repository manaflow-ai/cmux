import Darwin
import Foundation

/// Direct, killable filesystem helper for the app's per-cwd action catalog.
/// The CLI intercepts this private command before ordinary socket setup. Paths
/// arrive only as argv values and output uses a bounded binary frame.
struct CMUXActionCatalogReadHelper {
    static let command = "__action-catalog-read-v1"
    static let frameMagic = Data("CMUXCFG1".utf8)
    static let maximumConfigBytes = 4 << 20
    static let maximumPathBytes = 64 << 10

    private let fileManager: FileManager
    private let write: (Data) throws -> Void

    init(
        fileManager: FileManager = .default,
        write: @escaping (Data) throws -> Void = { data in
            try FileHandle.standardOutput.write(contentsOf: data)
        }
    ) {
        self.fileManager = fileManager
        self.write = write
    }

    func runIfRequested(arguments: [String]) -> Int32? {
        guard arguments.count > 1, arguments[1] == Self.command else { return nil }
        guard arguments.count == 5,
              let maximumBytes = Int(arguments[4]),
              (1...Self.maximumConfigBytes).contains(maximumBytes) else {
            return 64
        }

        let directory = arguments[2].isEmpty ? nil : arguments[2]
        guard directory.map({ ($0 as NSString).isAbsolutePath }) ?? true,
              (arguments[3] as NSString).isAbsolutePath else {
            return 64
        }

        let localPath = directory.map(resolvedLocalConfigPath(startingFrom:))
        guard localPath.map({ $0.utf8.count <= Self.maximumPathBytes }) ?? true else {
            return 74
        }
        let localPayload = localPath.map {
            readFile(at: $0, maximumBytes: maximumBytes)
        } ?? FilePayload(status: .missing, data: Data())
        let globalPayload = readFile(at: arguments[3], maximumBytes: maximumBytes)

        var frame = Self.frameMagic
        appendField(
            status: localPath == nil ? .missing : .data,
            payload: localPath.map { Data($0.utf8) } ?? Data(),
            to: &frame
        )
        appendField(status: localPayload.status, payload: localPayload.data, to: &frame)
        appendField(status: globalPayload.status, payload: globalPayload.data, to: &frame)
        do {
            try write(frame)
            return 0
        } catch {
            return 74
        }
    }

    private func resolvedLocalConfigPath(startingFrom directory: String) -> String {
        var current = directory
        while true {
            let candidates = [
                ((current as NSString).appendingPathComponent(".cmux") as NSString)
                    .appendingPathComponent("cmux.json"),
                (current as NSString).appendingPathComponent("cmux.json"),
            ]
            if let candidate = candidates.first(where: fileManager.fileExists(atPath:)) {
                return candidate
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return (((directory as NSString).appendingPathComponent(".cmux") as NSString)
            .appendingPathComponent("cmux.json"))
    }

    private func readFile(at path: String, maximumBytes: Int) -> FilePayload {
        guard fileManager.fileExists(atPath: path) else {
            return FilePayload(status: .missing, data: Data())
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return FilePayload(status: .unreadable, data: Data())
        }
        defer { try? handle.close() }

        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 << 10))
        do {
            while data.count <= maximumBytes {
                let remaining = maximumBytes + 1 - data.count
                guard remaining > 0,
                      let chunk = try handle.read(upToCount: min(remaining, 64 << 10)),
                      !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }
        } catch {
            return FilePayload(status: .unreadable, data: Data())
        }
        guard data.count <= maximumBytes else {
            return FilePayload(status: .tooLarge, data: Data())
        }
        return FilePayload(status: .data, data: data)
    }

    private func appendField(status: FieldStatus, payload: Data, to frame: inout Data) {
        frame.append(status.rawValue)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
    }
}

/// Copies one caller-selected regular file into app-controlled staging.
///
/// The app launches this private CLI command in its bounded, killable process
/// runner. Source `open`, `pread`, and filesystem close work therefore cannot
/// pin an in-process task or its attachment-preparation permit indefinitely.
struct CMUXTextBoxAttachmentSnapshotHelper {
    static let command = "__textbox-attachment-snapshot-v1"
    static let frameMagic = Data("CMUXATT1".utf8)
    static let maximumPathBytes = 64 << 10
    static let maximumFileBytes: off_t = 256 * 1024 * 1024
    private static let copyBufferSize = 64 << 10

    private let write: (Data) throws -> Void

    init(
        write: @escaping (Data) throws -> Void = { data in
            try FileHandle.standardOutput.write(contentsOf: data)
        }
    ) {
        self.write = write
    }

    func runIfRequested(arguments: [String]) -> Int32? {
        guard arguments.count > 1, arguments[1] == Self.command else {
            return nil
        }
        guard arguments.count == 5,
              let maximumBytes = off_t(arguments[4]),
              maximumBytes > 0,
              maximumBytes <= Self.maximumFileBytes else {
            return 64
        }

        let sourcePath = arguments[2]
        let destinationPath = arguments[3]
        guard sourcePath.utf8.count <= Self.maximumPathBytes,
              destinationPath.utf8.count <= Self.maximumPathBytes,
              (sourcePath as NSString).isAbsolutePath,
              (destinationPath as NSString).isAbsolutePath,
              sourcePath != destinationPath else {
            return 64
        }
        guard copyRegularFile(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            maximumBytes: maximumBytes
        ) else {
            return 74
        }
        do {
            try write(Self.frameMagic)
            return 0
        } catch {
            _ = destinationPath.withCString(Darwin.unlink)
            return 74
        }
    }

    private func copyRegularFile(
        sourcePath: String,
        destinationPath: String,
        maximumBytes: off_t
    ) -> Bool {
        let sourceDescriptor = sourcePath.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard sourceDescriptor >= 0 else { return false }
        defer { Darwin.close(sourceDescriptor) }

        var initialMetadata = stat()
        guard Darwin.fstat(sourceDescriptor, &initialMetadata) == 0,
              Self.isRegularFile(initialMetadata),
              initialMetadata.st_size >= 0,
              initialMetadata.st_size <= maximumBytes else {
            return false
        }

        let destinationDescriptor = destinationPath.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard destinationDescriptor >= 0 else { return false }
        var completed = false
        defer {
            Darwin.close(destinationDescriptor)
            if !completed {
                _ = destinationPath.withCString(Darwin.unlink)
            }
        }

        var buffer = [UInt8](
            repeating: 0,
            count: Self.copyBufferSize
        )
        var sourceOffset: off_t = 0
        while sourceOffset < initialMetadata.st_size {
            let requestedByteCount = Int(min(
                off_t(buffer.count),
                initialMetadata.st_size - sourceOffset
            ))
            let bytesRead = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return -1 }
                while true {
                    let result = Darwin.pread(
                        sourceDescriptor,
                        baseAddress,
                        requestedByteCount,
                        sourceOffset
                    )
                    if result < 0, errno == EINTR { continue }
                    return result
                }
            }
            guard bytesRead == requestedByteCount else { return false }

            var destinationOffset = 0
            while destinationOffset < bytesRead {
                let bytesWritten = buffer.withUnsafeBytes { bytes -> Int in
                    guard let baseAddress = bytes.baseAddress else { return -1 }
                    while true {
                        let result = Darwin.write(
                            destinationDescriptor,
                            baseAddress.advanced(by: destinationOffset),
                            bytesRead - destinationOffset
                        )
                        if result < 0, errno == EINTR { continue }
                        return result
                    }
                }
                guard bytesWritten > 0 else { return false }
                destinationOffset += bytesWritten
            }
            sourceOffset += off_t(bytesRead)
        }

        var finalMetadata = stat()
        guard Darwin.fstat(sourceDescriptor, &finalMetadata) == 0,
              Self.sameSnapshotIdentity(initialMetadata, finalMetadata),
              Darwin.ftruncate(
                destinationDescriptor,
                initialMetadata.st_size
              ) == 0 else {
            return false
        }
        completed = true
        return true
    }

    private static func isRegularFile(_ metadata: stat) -> Bool {
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private static func sameSnapshotIdentity(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
