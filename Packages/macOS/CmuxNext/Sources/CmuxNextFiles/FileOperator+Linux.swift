#if os(Linux)
import Foundation
import Glibc

/// Rename and copy on Linux, where `copyfile(3)` does not exist.
extension FileOperator {
    /// rename(2), which the instance method of that name hides.
    static func systemRename(_ source: String, _ target: String) -> Int32 {
        // SAFETY: rename reads the NUL-terminated copies of both paths made for the call.
        unsafe Glibc.rename(source, target)
    }

    /// Moves `url` to the home trash of the freedesktop.org Trash specification
    /// (`$XDG_DATA_HOME/Trash`, default `~/.local/share/Trash`), where the desktop's file manager
    /// lists and restores it: the `info/<name>.trashinfo` record is claimed first (O_EXCL), then
    /// the item moves to `files/<name>`, a name `namer` makes free there. The item's URL there.
    /// `trash` is the trash folder (tests pass a temporary one).
    static func systemTrash(_ url: URL, namer: FileNamer, in trash: URL = homeTrash()) throws -> URL {
        let files = trash.appendingPathComponent("files", isDirectory: true)
        let info = trash.appendingPathComponent("info", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        let taken = names(in: files).union(names(in: info).map { ($0 as NSString).deletingPathExtension })
        let name = namer.freeName(for: url.lastPathComponent, style: .number, taken: taken)
        let record = info.appendingPathComponent(name + ".trashinfo")
        let path = url.standardizedFileURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        let text = "[Trash Info]\nPath=\(path)\nDeletionDate=\(trashDate(Date()))\n"
        // SAFETY: open reads the NUL-terminated copy of the path made for the call.
        let fd = unsafe open(record.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileBrowserError.posix(errno) }
        let bytes = Array(text.utf8)
        var written = 0
        defer { close(fd) }
        do {
            while written < bytes.count { written += try writeChunk(fd, bytes[written...]) }
            let target = files.appendingPathComponent(name)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            try? FileManager.default.removeItem(at: record)
            throw error
        }
    }

    /// Removes the `.trashinfo` record of an item Put Back moved out of the home trash.
    static func forgetTrashed(_ trashed: URL) {
        let folder = trashed.deletingLastPathComponent()
        guard folder.lastPathComponent == "files" else { return }
        let record = folder.deletingLastPathComponent().appendingPathComponent("info", isDirectory: true)
            .appendingPathComponent(trashed.lastPathComponent + ".trashinfo")
        try? FileManager.default.removeItem(at: record)
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
        guard unsafe lstat(source, &info) == 0 else { throw FileBrowserError.posix(errno) }
        let mode = info.st_mode & 0o7777
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            // SAFETY: mkdir reads the NUL-terminated copy of the path made for the call.
            guard unsafe mkdir(target, mode | S_IRWXU) == 0 else { throw FileBrowserError.posix(errno) }
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: source) } catch {
                throw FileBrowserError.failed(error.localizedDescription)
            }
            for name in names {
                try copyItem(source + "/" + name, to: target + "/" + name, progress: progress)
            }
            // The owner's write bit let the children in; the folder now takes its own mode.
            // SAFETY: chmod reads the NUL-terminated copy of the path made for the call.
            guard unsafe chmod(target, mode) == 0 else { throw FileBrowserError.posix(errno) }
        case S_IFLNK:
            let destination: String
            do { destination = try FileManager.default.destinationOfSymbolicLink(atPath: source) } catch {
                throw FileBrowserError.failed(error.localizedDescription)
            }
            // SAFETY: symlink reads the NUL-terminated copies of both strings made for the call.
            guard unsafe symlink(destination, target) == 0 else { throw FileBrowserError.posix(errno) }
        case S_IFREG:
            try copyData(source, to: target, mode: mode, progress: progress)
        default:
            // A socket, FIFO or device node: copyfile copies none of their content either.
            throw FileBrowserError.posix(ENOTSUP)
        }
        // SAFETY: utimensat reads the NUL-terminated copy of the path and the two timespecs of the array, both made
        // for the call.
        _ = unsafe utimensat(AT_FDCWD, target, [info.st_atim, info.st_mtim], AT_SYMLINK_NOFOLLOW)
    }

    /// One regular file's bytes, 1 MiB at a time, into a new file with `mode`.
    private static func copyData(_ source: String, to target: String, mode: mode_t,
                                 progress: (Int64) -> Bool) throws {
        // SAFETY: open reads the NUL-terminated copy of the path made for the call.
        let input = unsafe open(source, O_RDONLY | O_CLOEXEC)
        guard input >= 0 else { throw FileBrowserError.posix(errno) }
        defer { close(input) }
        // SAFETY: as above; O_EXCL refuses an existing target, the copy's COPYFILE_EXCL.
        let output = unsafe open(target, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard output >= 0 else { throw FileBrowserError.posix(errno) }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var copied: Int64 = 0
        var count = 0
        repeat {
            count = try readChunk(input, into: &buffer)
            var written = 0
            while written < count {
                written += try writeChunk(output, buffer[written..<count])
            }
            copied += Int64(count)
            if count > 0, !progress(copied) { throw FileBrowserError.cancelled }
        } while count > 0
    }

    /// One read(2) into `buffer`, again after a signal; 0 at the end of the file.
    private static func readChunk(_ fd: Int32, into buffer: inout [UInt8]) throws -> Int {
        var result = 0
        repeat {
            // SAFETY: read writes at most bytes.count bytes into the array's own storage, lent for the call.
            result = unsafe buffer.withUnsafeMutableBytes { bytes in unsafe read(fd, bytes.baseAddress, bytes.count) }
        } while result < 0 && errno == EINTR
        guard result >= 0 else { throw FileBrowserError.posix(errno) }
        return result
    }

    /// One write(2) of a prefix of `bytes`, again after a signal; the count written.
    private static func writeChunk(_ fd: Int32, _ bytes: ArraySlice<UInt8>) throws -> Int {
        var result = 0
        repeat {
            // SAFETY: write reads at most raw.count bytes of the slice's own storage, lent for the call.
            result = unsafe bytes.withUnsafeBytes { raw in unsafe write(fd, raw.baseAddress, raw.count) }
        } while result < 0 && errno == EINTR
        guard result >= 0 else { throw FileBrowserError.posix(errno) }
        return result
    }
}
#endif
