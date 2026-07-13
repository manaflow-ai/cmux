import Darwin
import Foundation

/// Owns a pinned source-root descriptor for no-follow worktree-include reads.
final class WorktreeIncludeSourceRoot {
    static let resourceKeys: Set<URLResourceKey> = [
        .fileSizeKey,
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
    ]

    let rootURL: URL
    private let descriptor: Int32

    init(rootURL: URL) throws {
        self.rootURL = rootURL.standardizedFileURL
        descriptor = Darwin.open(
            self.rootURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw posixError() }
    }

    deinit {
        Darwin.close(descriptor)
    }

    func relativePath(for source: URL) throws -> String {
        let source = source.standardizedFileURL
        if source == rootURL { return "" }
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard source.path.hasPrefix(rootPrefix) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let relativePath = String(source.path.dropFirst(rootPrefix.count))
        _ = try components(for: relativePath)
        return relativePath
    }

    func preflight(
        _ sourceItem: URL,
        fileManager: FileManager,
        limits: WorktreeIncludeCopyLimits,
        itemCount: inout Int,
        byteCount: inout Int64
    ) throws {
        let rootValues = try sourceItem.resourceValues(forKeys: Self.resourceKeys)
        try account(
            sourceItem,
            rootValues,
            itemCount: &itemCount,
            byteCount: &byteCount
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { return }
        guard let enumerator = fileManager.enumerator(atPath: sourceItem.path) else {
            throw CocoaError(.fileReadUnknown)
        }
        while let relativePath = enumerator.nextObject() as? String {
            if Task.isCancelled { throw CancellationError() }
            let child = sourceItem.appendingPathComponent(relativePath)
            let values = try child.resourceValues(forKeys: Self.resourceKeys)
            try account(child, values, itemCount: &itemCount, byteCount: &byteCount)
            if itemCount > limits.maximumItemCount || byteCount > limits.maximumByteCount { return }
        }
    }

    func openRegularFile(at relativePath: String) throws -> Int32 {
        let (parent, name) = try openParent(of: relativePath)
        defer { Darwin.close(parent) }
        let fileDescriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fileDescriptor >= 0 else { throw posixError() }
        var status = stat()
        guard fstat(fileDescriptor, &status) == 0 else {
            Darwin.close(fileDescriptor)
            throw posixError()
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fileDescriptor)
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return fileDescriptor
    }

    func openDirectory(at relativePath: String) throws -> Int32 {
        try openDirectoryComponents(try components(for: relativePath))
    }

    func openSymbolicLink(at relativePath: String) throws -> Int32 {
        let (parent, name) = try openParent(of: relativePath)
        defer { Darwin.close(parent) }
        let descriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_SYMLINK)
        }
        guard descriptor >= 0 else { throw posixError() }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFLNK else {
            Darwin.close(descriptor)
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return descriptor
    }

    func openItem(at relativePath: String, values: URLResourceValues) throws -> Int32 {
        if values.isSymbolicLink == true {
            return try openSymbolicLink(at: relativePath)
        }
        if values.isDirectory == true {
            return try openDirectory(at: relativePath)
        }
        if values.isRegularFile == true {
            return try openRegularFile(at: relativePath)
        }
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func symbolicLinkTarget(at relativePath: String) throws -> [UInt8] {
        let (parent, name) = try openParent(of: relativePath)
        defer { Darwin.close(parent) }
        var status = stat()
        let statusResult = name.withCString {
            fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard statusResult == 0 else { throw posixError() }
        guard status.st_mode & S_IFMT == S_IFLNK else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let capacity = max(1, Int(status.st_size) + 1)
        var bytes = [UInt8](repeating: 0, count: capacity)
        let count = bytes.withUnsafeMutableBytes { buffer in
            name.withCString {
                readlinkat(parent, $0, buffer.baseAddress, buffer.count)
            }
        }
        guard count >= 0 else { throw posixError() }
        guard count < capacity else { throw posixError(EOVERFLOW) }
        return Array(bytes.prefix(count))
    }

    private func openParent(of relativePath: String) throws -> (descriptor: Int32, name: String) {
        var pathComponents = try components(for: relativePath)
        guard let name = pathComponents.popLast() else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return (try openDirectoryComponents(pathComponents), name)
    }

    private func openDirectoryComponents(_ pathComponents: [String]) throws -> Int32 {
        var current = Darwin.dup(descriptor)
        guard current >= 0 else { throw posixError() }
        do {
            for component in pathComponents {
                let next = component.withCString {
                    openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard next >= 0 else { throw posixError() }
                Darwin.close(current)
                current = next
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private func components(for relativePath: String) throws -> [String] {
        if relativePath.isEmpty { return [] }
        let pathComponents = relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard pathComponents.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0")
        }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return pathComponents
    }

    private func account(
        _ source: URL,
        _ values: URLResourceValues,
        itemCount: inout Int,
        byteCount: inout Int64
    ) throws {
        itemCount += 1
        if values.isRegularFile == true,
           values.isSymbolicLink != true,
           let size = values.fileSize {
            byteCount += Int64(size)
        }
        let descriptor = try openItem(
            at: relativePath(for: source),
            values: values
        )
        defer { Darwin.close(descriptor) }
        byteCount += try WorktreeIncludeExtendedAttributes(
            sourceDescriptor: descriptor
        ).byteCount
    }

    private func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
