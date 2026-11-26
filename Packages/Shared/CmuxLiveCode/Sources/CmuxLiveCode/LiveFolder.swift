// The live folder's disk side (LiveEngine.swift is the engine): its listing, the private copy of a
// patch that the signature check and dlopen read, its log and `status.json`. Plain POSIX, so it also
// builds and is tested on Linux. Same build gate as the engine: shipped iPhone builds compile none of it.
#if os(macOS) || DEBUG
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

// LiveFolder has an `open()` method, so its calls to the C functions go through these.
private func posixOpen(_ path: String, _ flags: Int32, _ mode: mode_t = 0) -> Int32 { open(path, flags, mode) }
private func posixRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ n: Int) -> Int { read(fd, buf, n) }
private func posixWrite(_ fd: Int32, _ buf: UnsafeRawPointer?, _ n: Int) -> Int { write(fd, buf, n) }

public enum LiveCodeError: Error, CustomStringConvertible {
    case open(String)
    case noImage
    case noInterposer
    case nothingToReplace
    case layoutChanged([String])
    case opaqueTypeChanged([String])
    case notOurTeam(String)
    case nothingToUndo
    case copy(String)

    public var description: String {
        switch self {
        case .open(let message): "dlopen failed: \(message)"
        case .noImage: "the patch is loaded but dyld does not list it"
        case .noInterposer: "dyld_dynamic_interpose is not available"
        case .nothingToReplace: "the patch defines no function this build has (built against another build?)"
        case .layoutChanged(let types): "stored properties changed, rebuild instead: \(types.joined(separator: ", "))"
        case .opaqueTypeChanged(let types):
            "a `some View` (or other opaque) result's type changed, rebuild instead (a view or modifier added or removed; "
                + "values, strings, colors and logic inside it apply live): \(types.joined(separator: "; "))"
        case .notOurTeam(let detail): "not signed by this app's team: \(detail)"
        case .nothingToUndo: "no patch is applied"
        case .copy(let detail): "cannot take a private copy: \(detail)"
        }
    }
}

/// One applied patch, as `status.json` lists it.
struct LivePatchRecord: Codable, Sendable {
    var name: String
    /// From the patch's sidecar (`NAME.json`, which patch.py writes): the commit and files built.
    var commit: String?
    var files: [String]?
    var functions: Int
    var appliedAt: Double
}

/// `status.json`: what this process has applied, newest first.
struct LiveStatus: Codable, Sendable {
    var pid: Int32
    /// The process's executable, so a reader can tell a reused pid from this app.
    var executable: String?
    var bundleID: String?
    /// Only patches this app's team signed load: outside Debug and bench, in an app signed by a team.
    var teamSignedOnly: Bool
    var folder: String
    var generation: Int
    var patches: [LivePatchRecord]
    var lastError: String?
    var updatedAt: Double
}

/// The live folder's disk side: its listing, its log (`live-code.log`) and `status.json`. Every
/// call reads or writes the disk: the engine actor makes them, off the main thread.
public struct LiveFolder: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Patches and undo requests, in name order. A hidden name is a file still being written.
    func entries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter {
            !$0.hasPrefix(".") && ($0.hasSuffix(".dylib") || $0.hasSuffix(".rollback") || $0.hasSuffix(".rollback-all"))
        }.sorted()
    }

    /// A private copy of the patch `name`, which the signature check and dlopen both read. The
    /// live folder is writable by any process of this user, and the NIGHTLY's entitlements turn off
    /// dyld's library validation (`disable-library-validation`), so checking the folder's file and
    /// then opening its path again could see two files. The patch is read without following a link
    /// and must be a regular file; the copy is created exclusively in a 0700 folder of this process
    /// in the per-user temporary directory, which must be a directory this user owns that nobody
    /// else can enter. The caller removes the copy once it is loaded (dyld keeps the mapping).
    func privateCopy(_ name: String) throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-live-code-\(getpid())", isDirectory: true)
        if mkdir(folder.path, 0o700) != 0, errno != EEXIST {
            throw LiveCodeError.copy("cannot make \(folder.path): errno \(errno)")
        }
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else {
            throw LiveCodeError.copy("\(folder.path) is not a folder only this user can enter")
        }
        let source = posixOpen(url.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW)
        guard source >= 0 else { throw LiveCodeError.copy("cannot open \(name) without following a link: errno \(errno)") }
        defer { close(source) }
        guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw LiveCodeError.copy("\(name) is not a regular file")
        }
        let copy = folder.appendingPathComponent(UUID().uuidString + ".dylib")
        let target = posixOpen(copy.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard target >= 0 else { throw LiveCodeError.copy("cannot create \(copy.path): errno \(errno)") }
        defer { close(target) }
        let size = Int(info.st_size)
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var copied = 0
        // Bounded by the size fstat gave; a file that grows meanwhile is copied only that far.
        for _ in 0...(size / buffer.count) where copied < size {
            let count = buffer.withUnsafeMutableBytes { posixRead(source, $0.baseAddress, min($0.count, size - copied)) }
            guard count > 0 else { throw LiveCodeError.copy("\(name) ended after \(copied) of \(size) bytes") }
            guard buffer.withUnsafeBytes({ Self.writeAll(target, $0.baseAddress, count) }) else {
                throw LiveCodeError.copy("cannot write \(copy.path): errno \(errno)")
            }
            copied += count
        }
        guard copied == size else { throw LiveCodeError.copy("\(name) ended after \(copied) of \(size) bytes") }
        return copy
    }

    struct Sidecar: Decodable {
        var commit: String?
        var files: [String]?
    }

    /// `NAME.json` beside the patch `NAME.dylib`, when patch.py wrote one.
    func sidecar(_ name: String) -> Sidecar? {
        guard name.hasSuffix(".dylib") else { return nil }
        let json = url.appendingPathComponent(String(name.dropLast(".dylib".count)) + ".json")
        guard let data = try? Data(contentsOf: json) else { return nil }
        return try? JSONDecoder().decode(Sidecar.self, from: data)
    }

    func writeStatus(_ status: LiveStatus) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(status) else { return }
        try? data.write(to: url.appendingPathComponent("status.json"), options: .atomic)
    }

    /// Appends one line to `live-code.log`.
    public func append(_ line: String) {
        let descriptor = posixOpen(url.appendingPathComponent("live-code.log").path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return }
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { Self.writeAll(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
    }

    /// Writes all `count` bytes, retrying a short write or an interrupted one.
    private static func writeAll(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Bool {
        guard let buffer else { return count == 0 }
        var written = 0
        while written < count {
            let result = posixWrite(descriptor, buffer + written, count - written)
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { return false }
            written += result
        }
        return true
    }
}
#endif
