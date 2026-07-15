import Darwin
import Foundation

extension FilePreviewTextSaver {

    static func saveTrustedWorkspaceNote(
        content: String,
        to url: URL,
        encoding: String.Encoding
    ) async -> Result {
        await Task.detached(priority: .userInitiated) {
            guard let data = content.data(using: encoding) else {
                return .failed(fileExists: FileManager.default.fileExists(atPath: url.path))
            }
            return writeTrustedWorkspaceNoteData(data, to: url)
        }.value
    }

    private static func writeTrustedWorkspaceNoteData(_ data: Data, to url: URL) -> Result {
        let path = (url.path as NSString).standardizingPath
        guard let projectRoot = NoteSupport.projectRoot(forNotePath: path),
              NoteSupport.projectNotesDirectoryIsTrusted(projectRoot: projectRoot) else {
            return .failed(fileExists: FileManager.default.fileExists(atPath: path))
        }
        let notesRoot = (NoteSupport.notesDirectory(forProjectRoot: projectRoot) as NSString)
            .standardizingPath
        guard path.hasPrefix(notesRoot + "/") else {
            return .failed(fileExists: FileManager.default.fileExists(atPath: path))
        }
        let relativePath = String(path.dropFirst(notesRoot.count + 1))
        let components = relativePath.split(separator: "/").map(String.init)
        guard let filename = components.last,
              !components.contains(where: { $0 == "." || $0 == ".." }) else {
            return .failed(fileExists: FileManager.default.fileExists(atPath: path))
        }

        let rootFD = notesRoot.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootFD >= 0 else {
            return .failed(fileExists: FileManager.default.fileExists(atPath: path))
        }
        var currentFD = rootFD
        defer {
            if currentFD != rootFD { Darwin.close(currentFD) }
            Darwin.close(rootFD)
        }

        for component in components.dropLast() {
            let nextFD = component.withCString {
                Darwin.openat(currentFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard nextFD >= 0 else {
                return .failed(fileExists: FileManager.default.fileExists(atPath: path))
            }
            if currentFD != rootFD { Darwin.close(currentFD) }
            currentFD = nextFD
        }

        guard writeAtomicallyReplacingRegularFile(data, filename: filename, inDirectoryFD: currentFD) else {
            return .failed(fileExists: FileManager.default.fileExists(atPath: path))
        }
        return .saved
    }

    private static func writeAtomicallyReplacingRegularFile(
        _ data: Data,
        filename: String,
        inDirectoryFD directoryFD: Int32
    ) -> Bool {
        var statBuffer = stat()
        let statResult = filename.withCString {
            Darwin.fstatat(directoryFD, $0, &statBuffer, AT_SYMLINK_NOFOLLOW)
        }
        let mode: mode_t
        if statResult == 0 {
            guard isRegularFile(mode: statBuffer.st_mode) else { return false }
            let existingFD = filename.withCString {
                Darwin.openat(directoryFD, $0, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard validateOpenedRegularFile(existingFD) >= 0 else { return false }
            Darwin.close(existingFD)
            mode = statBuffer.st_mode & mode_t(0o777)
        } else {
            guard errno == ENOENT else { return false }
            mode = mode_t(0o600)
        }

        let tempName = ".\(filename).cmux-save-\(UUID().uuidString).tmp"
        let tempFD = tempName.withCString {
            Darwin.openat(
                directoryFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode
            )
        }
        guard validateOpenedRegularFile(tempFD) >= 0 else { return false }
        defer { Darwin.close(tempFD) }

        var removeTemp = true
        defer {
            if removeTemp {
                _ = tempName.withCString { Darwin.unlinkat(directoryFD, $0, 0) }
            }
        }

        guard writeAll(data, toFileDescriptor: tempFD),
              syncFileDescriptor(tempFD) else {
            return false
        }
        let renamed = tempName.withCString { tempPointer in
            filename.withCString { filenamePointer in
                Darwin.renameat(directoryFD, tempPointer, directoryFD, filenamePointer)
            }
        }
        guard renamed == 0 else { return false }
        removeTemp = false
        return true
    }

    private static func validateOpenedRegularFile(_ fileFD: Int32) -> Int32 {
        guard fileFD >= 0 else { return -1 }
        var openedStat = stat()
        guard Darwin.fstat(fileFD, &openedStat) == 0,
              isRegularFile(mode: openedStat.st_mode) else {
            Darwin.close(fileFD)
            return -1
        }
        return fileFD
    }

    private static func isRegularFile(mode: mode_t) -> Bool {
        (mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }

    private static func writeAll(_ data: Data, toFileDescriptor fileFD: Int32) -> Bool {
        guard !data.isEmpty else { return true }
        return data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fileFD, baseAddress.advanced(by: offset), buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written == -1, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func syncFileDescriptor(_ fileFD: Int32) -> Bool {
        while true {
            if Darwin.fsync(fileFD) == 0 { return true }
            if errno == EINTR { continue }
            return false
        }
    }
}
