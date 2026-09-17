import Darwin
import Foundation

extension TerminalController {
    final class WorkspaceCreateIdempotencyFileStore: WorkspaceCreateIdempotencyPersisting, @unchecked Sendable {
        private struct Snapshot: Codable {
            let version: Int
            let operationIDs: [UUID]
        }

        private enum StoreError: Error {
            case unsupportedVersion(Int)
            case shortWrite
        }

        private static let version = 1
        private let fileManager: FileManager
        private let beforeRename: (() throws -> Void)?
        let fileURL: URL

        init(
            fileURL: URL = WorkspaceCreateIdempotencyFileStore.defaultFileURL(),
            fileManager: FileManager = .default,
            beforeRename: (() throws -> Void)? = nil
        ) {
            self.fileURL = fileURL
            self.fileManager = fileManager
            self.beforeRename = beforeRename
        }

        func loadOperationIDs() throws -> [UUID] {
            try removeStaleTemporaryFiles()
            guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
            guard snapshot.version == Self.version else {
                throw StoreError.unsupportedVersion(snapshot.version)
            }
            return snapshot.operationIDs
        }

        func saveOperationIDs(_ operationIDs: [UUID]) throws {
            let snapshot = Snapshot(version: Self.version, operationIDs: operationIDs)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            let directoryURL = fileURL.deletingLastPathComponent()
            let directoryExisted = fileManager.fileExists(atPath: directoryURL.path)
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if !directoryExisted {
                try Self.synchronizeDirectory(at: directoryURL.deletingLastPathComponent())
            }

            let temporaryURL = directoryURL.appendingPathComponent(
                ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
                isDirectory: false
            )
            do {
                try Self.writeAndFullSync(data, to: temporaryURL)
                try beforeRename?()
                try Self.rename(temporaryURL, to: fileURL)
                try Self.synchronizeDirectory(at: directoryURL)
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                throw error
            }
        }

        private func removeStaleTemporaryFiles() throws {
            let directoryURL = fileURL.deletingLastPathComponent()
            guard fileManager.fileExists(atPath: directoryURL.path) else { return }
            let prefix = ".\(fileURL.lastPathComponent)."
            for candidate in try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            ) where candidate.lastPathComponent.hasPrefix(prefix)
                && candidate.pathExtension == "tmp" {
                try fileManager.removeItem(at: candidate)
            }
        }

        private static func defaultFileURL() -> URL {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            let rawBundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
            let bundleID = rawBundleID.map { character in
                character.isLetter || character.isNumber || character == "." || character == "-"
                    ? character
                    : "_"
            }
            return appSupport
                .appendingPathComponent("cmux", isDirectory: true)
                .appendingPathComponent(
                    "workspace-create-tombstones-\(String(bundleID))-v1.json",
                    isDirectory: false
                )
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
}
