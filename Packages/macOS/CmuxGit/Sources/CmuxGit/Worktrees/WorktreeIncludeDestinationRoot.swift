import Darwin
import Foundation

/// Owns a verified destination-root descriptor for no-follow worktree writes.
final class WorktreeIncludeDestinationRoot {
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

    func relativePath(for destination: URL) throws -> String {
        let destination = destination.standardizedFileURL
        if destination == rootURL { return "" }
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard destination.path.hasPrefix(rootPrefix) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let relativePath = String(destination.path.dropFirst(rootPrefix.count))
        _ = try components(for: relativePath)
        return relativePath
    }

    func itemExists(at relativePath: String) throws -> Bool {
        guard !relativePath.isEmpty else { return true }
        let parentAndName: (descriptor: Int32, name: String)
        do {
            parentAndName = try openParent(of: relativePath)
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return false
        }
        let (parent, name) = parentAndName
        defer { Darwin.close(parent) }
        var status = stat()
        let result = name.withCString {
            fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return true }
        if errno == ENOENT { return false }
        throw posixError()
    }

    func directoryExists(at relativePath: String) throws -> Bool {
        guard !relativePath.isEmpty else { return true }
        let parentAndName: (descriptor: Int32, name: String)
        do {
            parentAndName = try openParent(of: relativePath)
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return false
        }
        let (parent, name) = parentAndName
        defer { Darwin.close(parent) }
        var status = stat()
        let result = name.withCString {
            fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result == -1, errno == ENOENT { return false }
        guard result == 0 else { throw posixError() }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw posixError(ENOTDIR)
        }
        return true
    }

    func createDirectory(
        at relativePath: String,
        permissions: mode_t
    ) throws -> (device: dev_t, inode: ino_t) {
        let (parent, name) = try openParent(of: relativePath)
        defer { Darwin.close(parent) }
        let temporaryName = ".cmux-worktreeinclude-\(UUID().uuidString)"
        let createResult = temporaryName.withCString { mkdirat(parent, $0, permissions) }
        guard createResult == 0 else { throw posixError() }
        var installed = false
        defer {
            if !installed {
                _ = temporaryName.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
            }
        }
        let temporaryDescriptor = temporaryName.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard temporaryDescriptor >= 0 else { throw posixError() }
        defer { Darwin.close(temporaryDescriptor) }
        var status = stat()
        guard fstat(temporaryDescriptor, &status) == 0 else { throw posixError() }
        let installResult = temporaryName.withCString { temporaryPointer in
            name.withCString { namePointer in
                renameatx_np(parent, temporaryPointer, parent, namePointer, UInt32(RENAME_EXCL))
            }
        }
        guard installResult == 0 else { throw posixError() }
        installed = true
        return (status.st_dev, status.st_ino)
    }

    func createRegularFile(at relativePath: String, permissions: mode_t) throws -> Int32 {
        let (parent, name) = try openParent(of: relativePath)
        defer { Darwin.close(parent) }
        let fileDescriptor = name.withCString {
            openat(
                parent,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                permissions
            )
        }
        guard fileDescriptor >= 0 else { throw posixError() }
        return fileDescriptor
    }

    func createSymbolicLink(
        at relativePath: String,
        target: [UInt8]
    ) throws -> (device: dev_t, inode: ino_t) {
        let (parent, name) = try openParent(of: relativePath)
        defer { Darwin.close(parent) }
        let temporaryName = ".cmux-worktreeinclude-\(UUID().uuidString)"
        var terminatedTarget = target
        terminatedTarget.append(0)
        let result: Int32 = terminatedTarget.withUnsafeBytes { targetBuffer in
            let targetPointer = targetBuffer.baseAddress!.assumingMemoryBound(to: CChar.self)
            return temporaryName.withCString { namePointer in
                symlinkat(targetPointer, parent, namePointer)
            }
        }
        guard result == 0 else { throw posixError() }
        var installed = false
        defer {
            if !installed {
                _ = temporaryName.withCString { unlinkat(parent, $0, 0) }
            }
        }
        var status = stat()
        let statusResult = temporaryName.withCString {
            fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard statusResult == 0 else { throw posixError() }
        let installResult = temporaryName.withCString { temporaryPointer in
            name.withCString { namePointer in
                renameatx_np(parent, temporaryPointer, parent, namePointer, UInt32(RENAME_EXCL))
            }
        }
        guard installResult == 0 else { throw posixError() }
        installed = true
        return (status.st_dev, status.st_ino)
    }

    func removeItemIfUnchanged(
        at relativePath: String,
        device: dev_t,
        inode: ino_t,
        isDirectory: Bool
    ) throws {
        guard !relativePath.isEmpty else { return }
        let (parent, name) = try openParent(of: relativePath)
        defer { Darwin.close(parent) }
        var status = stat()
        let statusResult = name.withCString {
            fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if statusResult == -1, errno == ENOENT { return }
        guard statusResult == 0 else { throw posixError() }
        guard status.st_dev == device,
              status.st_ino == inode,
              (status.st_mode & S_IFMT == S_IFDIR) == isDirectory else { return }
        let flags = isDirectory ? AT_REMOVEDIR : 0
        let result = name.withCString { unlinkat(parent, $0, flags) }
        if result == 0 || errno == ENOENT { return }
        throw posixError()
    }

    func applySecurityMetadata(
        sourceDescriptor: Int32,
        to relativePath: String,
        expectedDevice: dev_t,
        expectedInode: ino_t
    ) throws {
        let destinationDescriptor = try openItem(
            at: relativePath,
            flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        defer { Darwin.close(destinationDescriptor) }
        var destinationStatus = stat()
        guard fstat(destinationDescriptor, &destinationStatus) == 0 else { throw posixError() }
        guard destinationStatus.st_dev == expectedDevice,
              destinationStatus.st_ino == expectedInode else {
            throw posixError(ESTALE)
        }
        guard fcopyfile(
            sourceDescriptor,
            destinationDescriptor,
            nil,
            copyfile_flags_t(COPYFILE_SECURITY)
        ) == 0 else {
            throw posixError()
        }
    }

    func applySecurityMetadata(sourceDescriptor: Int32, destinationDescriptor: Int32) throws {
        guard fcopyfile(
            sourceDescriptor,
            destinationDescriptor,
            nil,
            copyfile_flags_t(COPYFILE_SECURITY)
        ) == 0 else {
            throw posixError()
        }
    }

    func copyRegularFileContents(
        sourceDescriptor: Int32,
        destinationDescriptor: Int32,
        itemCount: Int,
        byteCount: Int64,
        maximumByteCount: Int64,
        availableByteBudget: Int64
    ) throws -> Int64 {
        var byteCount = byteCount
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if Task.isCancelled { throw CancellationError() }
            let readCount = buffer.withUnsafeMutableBytes {
                Darwin.read(sourceDescriptor, $0.baseAddress, $0.count)
            }
            if readCount == -1, errno == EINTR { continue }
            guard readCount >= 0 else { throw posixError() }
            if readCount == 0 { break }
            let nextByteCount = byteCount + Int64(readCount)
            guard nextByteCount <= maximumByteCount else {
                throw WorktreeIncludeCopyLimitError(
                    itemCount: itemCount,
                    byteCount: nextByteCount,
                    reason: .resourceLimit
                )
            }
            guard nextByteCount <= availableByteBudget else {
                throw WorktreeIncludeCopyLimitError(
                    itemCount: itemCount,
                    byteCount: nextByteCount,
                    reason: .capacity
                )
            }
            var written = 0
            while written < readCount {
                let writeCount = buffer.withUnsafeBytes {
                    Darwin.write(
                        destinationDescriptor,
                        $0.baseAddress?.advanced(by: written),
                        readCount - written
                    )
                }
                if writeCount == -1, errno == EINTR { continue }
                guard writeCount > 0 else { throw posixError() }
                written += writeCount
            }
            byteCount = nextByteCount
        }
        try applySecurityMetadata(
            sourceDescriptor: sourceDescriptor,
            destinationDescriptor: destinationDescriptor
        )
        return byteCount
    }

    private func openItem(at relativePath: String, flags: Int32) throws -> Int32 {
        let (parent, name) = try openParent(of: relativePath)
        defer { Darwin.close(parent) }
        let itemDescriptor = name.withCString { openat(parent, $0, flags) }
        guard itemDescriptor >= 0 else { throw posixError() }
        return itemDescriptor
    }

    private func openParent(of relativePath: String) throws -> (descriptor: Int32, name: String) {
        var pathComponents = try components(for: relativePath)
        guard let name = pathComponents.popLast() else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return (try openDirectory(pathComponents), name)
    }

    private func openDirectory(_ pathComponents: [String]) throws -> Int32 {
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
        let pathComponents = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !pathComponents.isEmpty,
              pathComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return pathComponents
    }

    private func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
