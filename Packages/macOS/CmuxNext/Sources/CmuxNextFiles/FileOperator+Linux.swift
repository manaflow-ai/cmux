#if os(Linux)
import CmuxNextCompat
import Foundation
import Glibc

/// Rename, trash and copy on Linux, where `copyfile(3)` and the Finder Trash do not exist. Every
/// file call goes through its checked blocking seam (CmuxNextCompat/Threading).
extension FileOperator {
    /// rename(2), which the instance method of that name hides.
    static func systemRename(_ source: String, _ target: String) -> Int32 {
        // SAFETY: rename reads the NUL-terminated copies of both paths made for the call.
        unsafe blockingRename(source, target)
    }

    /// Moves `url` to the home trash of the freedesktop.org Trash specification
    /// (`$XDG_DATA_HOME/Trash`, default `~/.local/share/Trash`), where the desktop's file manager
    /// lists and restores it: the `info/<name>.trashinfo` record is claimed first (O_EXCL), then
    /// the item moves to `files/<name>`, a name `namer` makes free there. The item's URL there.
    /// `trash` is the trash folder (tests pass a temporary one).
    static func systemTrash(_ url: URL, namer: FileNamer, in trash: URL = homeTrash()) throws -> URL {
        let files = trash.appendingPathComponent("files", isDirectory: true)
        let info = trash.appendingPathComponent("info", isDirectory: true)
        try FileManager.checked.createDirectory(at: files, withIntermediateDirectories: true)
        try FileManager.checked.createDirectory(at: info, withIntermediateDirectories: true)
        let taken = names(in: files).union(names(in: info).map { ($0 as NSString).deletingPathExtension })
        let name = namer.freeName(for: url.lastPathComponent, style: .number, taken: taken)
        let record = info.appendingPathComponent(name + ".trashinfo")
        let path = url.standardizedFileURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        let text = "[Trash Info]\nPath=\(path)\nDeletionDate=\(trashDate(Date()))\n"
        // SAFETY: open reads the NUL-terminated copy of the path made for the call.
        let fd = unsafe blockingOpen(record.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileBrowserError.posix(errno) }
        defer { close(fd) }
        do {
            try writeAll(fd, Array(text.utf8)[...], at: 0)
            let target = files.appendingPathComponent(name)
            try FileManager.checked.moveItem(at: url, to: target)
            return target
        } catch {
            try? FileManager.checked.removeItem(at: record)
            throw error
        }
    }

    /// Removes the `.trashinfo` record of an item Put Back moved out of the home trash.
    static func forgetTrashed(_ trashed: URL) {
        let folder = trashed.deletingLastPathComponent()
        guard folder.lastPathComponent == "files" else { return }
        let record = folder.deletingLastPathComponent().appendingPathComponent("info", isDirectory: true)
            .appendingPathComponent(trashed.lastPathComponent + ".trashinfo")
        try? FileManager.checked.removeItem(at: record)
    }

    /// `$XDG_DATA_HOME/Trash`, or `~/.local/share/Trash` when it is unset or not absolute.
    static func homeTrash() -> URL {
        let data = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        let base = data.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share", isDirectory: true)
        return base.appendingPathComponent("Trash", isDirectory: true)
    }

    /// The specification's DeletionDate: local time as `YYYY-MM-DDThh:mm:ss`.
    static func trashDate(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        return "\(String(format: "%04d", parts.year ?? 0))-\(two(parts.month))-\(two(parts.day))T"
            + "\(two(parts.hour)):\(two(parts.minute)):\(two(parts.second))"
    }

    /// Copies `source` to `target` as `copyfile` does with `COPYFILE_ALL | COPYFILE_RECURSIVE |
    /// COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC`: folders recursively, a symlink as a link (never
    /// followed), modes and modification times kept, and an existing `target` refused. File data
    /// goes through a read and write loop, as Chromium's base::CopyFile does on POSIX
    /// (base/files/file_util_posix.cc). `progress` gets the bytes copied of the current file and
    /// returns false to stop; it is called only during this call.
    static func copy(_ source: URL, to target: URL, progress: (Int64) -> Bool) throws {
        try copyItem(source.path, to: target.path, progress: progress)
    }

    private static func copyItem(_ source: String, to target: String, progress: (Int64) -> Bool) throws {
        var info = stat()
        // SAFETY: lstat reads the NUL-terminated copy of the path made for the call and writes one struct stat into
        // `info`, a local live for the call.
        guard unsafe blockingLstat(source, &info) == 0 else { throw FileBrowserError.posix(errno) }
        let mode = info.st_mode & 0o7777
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            // SAFETY: mkdir reads the NUL-terminated copy of the path made for the call.
            guard unsafe blockingMkdir(target, mode | S_IRWXU) == 0 else { throw FileBrowserError.posix(errno) }
            let names: [String]
            do { names = try FileManager.checked.contentsOfDirectory(atPath: source) } catch {
                throw FileBrowserError.failed(error.localizedDescription)
            }
            for name in names {
                try copyItem(source + "/" + name, to: target + "/" + name, progress: progress)
            }
            // The owner's write bit let the children in; the folder now takes its own mode.
            // SAFETY: chmod reads the NUL-terminated copy of the path made for the call.
            guard unsafe blockingChmod(target, mode) == 0 else { throw FileBrowserError.posix(errno) }
        case S_IFLNK:
            do {
                let destination = try FileManager.checked.destinationOfSymbolicLink(atPath: source)
                try FileManager.checked.createSymbolicLink(atPath: target, withDestinationPath: destination)
            } catch {
                throw FileBrowserError.failed(error.localizedDescription)
            }
        case S_IFREG:
            try copyData(source, to: target, mode: mode, progress: progress)
        default:
            // A socket, FIFO or device node: copyfile copies none of their content either.
            throw FileBrowserError.posix(ENOTSUP)
        }
        // SAFETY: utimensat reads the NUL-terminated copy of the path and the two timespecs of the array, both made
        // for the call.
        _ = blockingCall(.fsMetadata) {
            unsafe utimensat(AT_FDCWD, target, [info.st_atim, info.st_mtim], AT_SYMLINK_NOFOLLOW)
        }
    }

    /// One regular file's bytes, 1 MiB at a time, into a new file with `mode`.
    private static func copyData(_ source: String, to target: String, mode: mode_t,
                                 progress: (Int64) -> Bool) throws {
        // SAFETY: open reads the NUL-terminated copy of the path made for the call.
        let input = unsafe blockingOpen(source, O_RDONLY | O_CLOEXEC)
        guard input >= 0 else { throw FileBrowserError.posix(errno) }
        defer { close(input) }
        // SAFETY: as above; O_EXCL refuses an existing target, the copy's COPYFILE_EXCL.
        let output = unsafe blockingOpen(target, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard output >= 0 else { throw FileBrowserError.posix(errno) }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var copied: Int64 = 0
        var count = try readChunk(input, into: &buffer, at: 0)
        // Each pass copies one chunk; a read of 0 (the end of the file) or an error ends the copy.
        while count > 0 {
            try writeAll(output, buffer[0..<count], at: copied)
            copied += Int64(count)
            guard progress(copied) else { throw FileBrowserError.cancelled }
            count = try readChunk(input, into: &buffer, at: copied)
        }
    }

    /// One pread(2) into `buffer` at `offset`, again after a signal; 0 at the end of the file.
    private static func readChunk(_ fd: Int32, into buffer: inout [UInt8], at offset: Int64) throws -> Int {
        func read() -> Int {
            // SAFETY: pread writes at most bytes.count bytes into the array's own storage, lent for the call.
            unsafe buffer.withUnsafeMutableBytes { bytes in unsafe blockingPread(fd, bytes.baseAddress, bytes.count, off_t(offset)) }
        }
        var result = read()
        while result < 0, errno == EINTR { result = read() }
        guard result >= 0 else { throw FileBrowserError.posix(errno) }
        return result
    }

    /// Writes all of `bytes` with pwrite(2) from `offset`, again after a signal or a short write.
    private static func writeAll(_ fd: Int32, _ bytes: ArraySlice<UInt8>, at offset: Int64) throws {
        var written = 0
        while written < bytes.count {
            // SAFETY: pwrite reads at most raw.count bytes of the slice's own storage, lent for the call.
            let result = unsafe bytes.dropFirst(written).withUnsafeBytes { raw in
                unsafe blockingPwrite(fd, raw.baseAddress, raw.count, off_t(offset) + off_t(written))
            }
            if result < 0 {
                guard errno == EINTR else { throw FileBrowserError.posix(errno) }
                continue
            }
            written += result
        }
    }
}
#endif
