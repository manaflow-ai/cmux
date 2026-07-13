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

    func createDirectory(at relativePath: String, permissions: mode_t) throws {
        let (parent, name) = try openParent(of: relativePath)
        defer { Darwin.close(parent) }
        let result = name.withCString { mkdirat(parent, $0, permissions) }
        guard result == 0 else { throw posixError() }
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

    func createSymbolicLink(at relativePath: String, target: [UInt8]) throws {
        let (parent, name) = try openParent(of: relativePath)
        defer { Darwin.close(parent) }
        var terminatedTarget = target
        terminatedTarget.append(0)
        let result: Int32 = terminatedTarget.withUnsafeBytes { targetBuffer in
            let targetPointer = targetBuffer.baseAddress!.assumingMemoryBound(to: CChar.self)
            return name.withCString { namePointer in
                symlinkat(targetPointer, parent, namePointer)
            }
        }
        guard result == 0 else { throw posixError() }
    }

    func removeItem(at relativePath: String) throws {
        guard !relativePath.isEmpty else { return }
        let (parent, name) = try openParent(of: relativePath)
        defer { Darwin.close(parent) }
        try removeItem(named: name, from: parent)
    }

    func applySecurityMetadata(
        from source: URL,
        to relativePath: String,
        isDirectory: Bool
    ) throws {
        let sourceFlags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (isDirectory ? O_DIRECTORY : 0)
        let sourceDescriptor = Darwin.open(source.path, sourceFlags)
        guard sourceDescriptor >= 0 else { throw posixError() }
        defer { Darwin.close(sourceDescriptor) }

        let destinationDescriptor = try openItem(
            at: relativePath,
            flags: (isDirectory ? O_RDONLY | O_DIRECTORY : O_WRONLY) | O_CLOEXEC | O_NOFOLLOW
        )
        defer { Darwin.close(destinationDescriptor) }
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

    private func openItem(at relativePath: String, flags: Int32) throws -> Int32 {
        let (parent, name) = try openParent(of: relativePath)
        defer { Darwin.close(parent) }
        let itemDescriptor = name.withCString { openat(parent, $0, flags) }
        guard itemDescriptor >= 0 else { throw posixError() }
        return itemDescriptor
    }

    private func removeItem(named name: String, from parent: Int32) throws {
        var status = stat()
        let statusResult = name.withCString {
            fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if statusResult == -1, errno == ENOENT { return }
        guard statusResult == 0 else { throw posixError() }

        if status.st_mode & S_IFMT == S_IFDIR {
            let child = name.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard child >= 0 else { throw posixError() }
            guard let directory = fdopendir(child) else {
                Darwin.close(child)
                throw posixError()
            }
            defer { closedir(directory) }
            while let entry = readdir(directory) {
                let childName = withUnsafeBytes(of: entry.pointee.d_name) {
                    String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                guard childName != ".", childName != ".." else { continue }
                try removeItem(named: childName, from: child)
            }
            let result = name.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
            if result == 0 || errno == ENOENT { return }
            throw posixError()
        }

        let result = name.withCString { unlinkat(parent, $0, 0) }
        if result == 0 || errno == ENOENT { return }
        throw posixError()
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
