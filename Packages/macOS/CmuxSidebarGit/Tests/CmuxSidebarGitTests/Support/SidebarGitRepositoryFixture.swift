import Foundation

/// Isolated one-file repository used by cross-window snapshot tests.
final class SidebarGitRepositoryFixture {
    let root: URL
    let gitDirectory: URL
    let trackedFile: URL
    let nestedDirectory: URL

    init(contents: String = "hello") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-git-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        trackedFile = root.appendingPathComponent("file.txt")
        nestedDirectory = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: gitDirectory.appendingPathComponent("refs/heads", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "ref: refs/heads/main\n".write(
            to: gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "\(String(repeating: "f", count: 40))\n".write(
            to: gitDirectory.appendingPathComponent("refs/heads/main"),
            atomically: true,
            encoding: .utf8
        )
        try contents.write(to: trackedFile, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: nestedDirectory,
            withIntermediateDirectories: true
        )
        try makeIndexData().write(to: gitDirectory.appendingPathComponent("index"))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeIndexData() -> Data {
        var fileStat = stat()
        _ = lstat(trackedFile.path, &fileStat)
        var bytes = Array("DIRC".utf8)
        bytes += Self.bigEndian(UInt32(2))
        bytes += Self.bigEndian(UInt32(1))
        let entryStart = bytes.count
        bytes += Self.bigEndian(UInt32(0))
        bytes += Self.bigEndian(UInt32(0))
        bytes += Self.bigEndian(UInt32(truncatingIfNeeded: fileStat.st_mtimespec.tv_sec))
        bytes += Self.bigEndian(UInt32(truncatingIfNeeded: fileStat.st_mtimespec.tv_nsec))
        bytes += Self.bigEndian(UInt32(0))
        bytes += Self.bigEndian(UInt32(0))
        bytes += Self.bigEndian(UInt32(0o100644))
        bytes += Self.bigEndian(UInt32(0))
        bytes += Self.bigEndian(UInt32(0))
        bytes += Self.bigEndian(UInt32(truncatingIfNeeded: fileStat.st_size))
        bytes += Array(repeating: UInt8(0xAA), count: 20)
        let path = Array("file.txt".utf8)
        bytes += Self.bigEndian(UInt16(path.count))
        bytes += path
        bytes.append(0)
        let padding = (8 - ((bytes.count - entryStart) % 8)) % 8
        bytes += Array(repeating: 0, count: padding)
        bytes += Array(repeating: UInt8(0xAB), count: 20)
        return Data(bytes)
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
    }

    private static func bigEndian(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }
}
