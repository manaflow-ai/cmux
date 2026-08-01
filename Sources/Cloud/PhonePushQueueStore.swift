import Darwin
import Foundation

/// Atomic, credential-free, bounded persistence for queued push envelopes.
actor PhonePushQueueStore {
    private enum StoreError: Error {
        case fileTooLarge
        case shortWrite
    }

    private static let maximumFileBytes = 8 * 1024 * 1024
    private let fileURL: URL
    private let capacity: Int
    private let fileManager: FileManager

    init(
        fileURL: URL,
        capacity: Int = PhonePushSerialDeliveryQueue.defaultCapacity,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.capacity = max(1, capacity)
        self.fileManager = fileManager
    }

    static func live() -> Self {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return Self(fileURL: root
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("phone-push-queue-v1.json"))
    }

    func load(nowEpochSeconds: Int) throws -> [PhonePushRequestEnvelope] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue
            ?? (Self.maximumFileBytes + 1)
        guard fileSize <= Self.maximumFileBytes else {
            try? clear()
            throw StoreError.fileTooLarge
        }
        let data = try Data(contentsOf: fileURL)
        let decoded: [PhonePushRequestEnvelope]
        do {
            decoded = try JSONDecoder().decode(
                [PhonePushRequestEnvelope].self,
                from: data
            )
        } catch {
            // A bad snapshot cannot heal while it remains at the live path.
            // The client still receives the original error and records the
            // load failure while recovering with an empty in-memory queue.
            try? clear()
            throw error
        }
        let current = decoded.filter { !$0.isExpired(at: nowEpochSeconds) }
        return Array(
            PhonePushSerialDeliveryQueue.normalized(current).suffix(capacity)
        )
    }

    func save(_ envelopes: [PhonePushRequestEnvelope]) throws {
        let bounded = Array(
            PhonePushSerialDeliveryQueue.normalized(envelopes).suffix(capacity)
        )
        guard !bounded.isEmpty else {
            try clear()
            return
        }
        let directoryURL = fileURL.deletingLastPathComponent()
        let directoryExisted = fileManager.fileExists(atPath: directoryURL.path)
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        if !directoryExisted {
            try Self.synchronizeDirectory(at: directoryURL.deletingLastPathComponent())
        }
        let data = try JSONEncoder().encode(bounded)
        guard data.count <= Self.maximumFileBytes else {
            throw StoreError.fileTooLarge
        }
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            try Self.writeAndFullSync(data, to: temporaryURL)
            try Self.rename(temporaryURL, to: fileURL)
            try Self.synchronizeDirectory(at: directoryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
        try Self.synchronizeDirectory(at: fileURL.deletingLastPathComponent())
    }

    private static func writeAndFullSync(_ data: Data, to url: URL) throws {
        let descriptor = try openDescriptor(
            url,
            flags: O_WRONLY | O_CREAT | O_EXCL,
            permissions: S_IRUSR | S_IWUSR
        )
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
        }
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(path: url.path)
                }
                guard written > 0 else { throw StoreError.shortWrite }
                offset += written
            }
        }
        try retryingInterruptedCall(path: url.path) {
            Darwin.fcntl(descriptor, F_FULLFSYNC)
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptorIsOpen = false
            throw posixError(path: url.path)
        }
        descriptorIsOpen = false
    }

    private static func rename(_ source: URL, to destination: URL) throws {
        try source.withUnsafeFileSystemRepresentation { sourcePath in
            try destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                try retryingInterruptedCall(path: destination.path) {
                    Darwin.rename(sourcePath, destinationPath)
                }
            }
        }
    }

    private static func synchronizeDirectory(at url: URL) throws {
        let descriptor = try openDescriptor(url, flags: O_RDONLY, permissions: 0)
        defer { _ = Darwin.close(descriptor) }
        try retryingInterruptedCall(path: url.path) {
            Darwin.fsync(descriptor)
        }
    }

    private static func openDescriptor(
        _ url: URL,
        flags: Int32,
        permissions: mode_t
    ) throws -> Int32 {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileWriteInvalidFileName) }
            let descriptor = Darwin.open(path, flags, permissions)
            guard descriptor >= 0 else { throw posixError(path: url.path) }
            return descriptor
        }
    }

    private static func retryingInterruptedCall(
        path: String,
        _ call: () -> Int32
    ) throws {
        while true {
            if call() == 0 { return }
            if errno == EINTR { continue }
            throw posixError(path: path)
        }
    }

    private static func posixError(path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: path]
        )
    }
}
