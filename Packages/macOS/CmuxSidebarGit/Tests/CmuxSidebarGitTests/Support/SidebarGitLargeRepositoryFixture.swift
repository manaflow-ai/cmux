import Foundation

/// Minimal on-disk repository with a configurable v2 index entry count.
final class SidebarGitLargeRepositoryFixture {
    let root: URL
    private let gitDirectory: URL

    init(entryCount: Int) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-git-large-\(UUID().uuidString)", isDirectory: true)
        gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        let refs = gitDirectory.appendingPathComponent("refs/heads", isDirectory: true)
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(
            to: gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "0000000000000000000000000000000000000000\n".write(
            to: refs.appendingPathComponent("main"),
            atomically: true,
            encoding: .utf8
        )
        try Self.indexData(entryCount: entryCount).write(to: gitDirectory.appendingPathComponent("index"))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private static func indexData(entryCount: Int) -> Data {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: Array("DIRC".utf8))
        bytes.append(contentsOf: bigEndian(UInt32(2)))
        bytes.append(contentsOf: bigEndian(UInt32(entryCount)))
        for index in 0..<entryCount {
            let entryStart = bytes.count
            let path = Array(String(format: "Sources/generated/%05d.swift", index).utf8)
            bytes.append(contentsOf: Array(repeating: 0, count: 8))
            bytes.append(contentsOf: bigEndian(UInt32(1)))
            bytes.append(contentsOf: bigEndian(UInt32(0)))
            bytes.append(contentsOf: Array(repeating: 0, count: 8))
            bytes.append(contentsOf: bigEndian(UInt32(0o100644)))
            bytes.append(contentsOf: Array(repeating: 0, count: 8))
            bytes.append(contentsOf: bigEndian(UInt32(0)))
            bytes.append(contentsOf: Array(repeating: 0, count: 20))
            bytes.append(contentsOf: bigEndian(UInt16(path.count)))
            bytes.append(contentsOf: path)
            bytes.append(0)
            let padding = (8 - ((bytes.count - entryStart) % 8)) % 8
            bytes.append(contentsOf: Array(repeating: 0, count: padding))
        }
        bytes.append(contentsOf: Array(repeating: 0xAB, count: 20))
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
