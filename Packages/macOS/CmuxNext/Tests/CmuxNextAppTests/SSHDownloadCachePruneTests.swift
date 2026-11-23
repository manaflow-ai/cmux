import CmuxNextRemote
import Foundation
import Testing

/// The ssh-next download cache keeps the build in use and the last two used of each artifact, not
/// every build ever fetched: Leo's nightly held 198 acpmux builds (11.9 GB, ~97 MB each), 9-32 new
/// a day, none ever removed.
struct SSHDownloadCachePruneTests {
    private static let artifact = "cmux-tui-acpmux-aarch64-apple-darwin"

    private func cache() throws -> SSHPaths {
        let paths = SSHPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("sdc-\(UUID().uuidString.prefix(8))"))
        try paths.prepare()
        return paths
    }

    /// Writes `name` into the cache, last used `age` seconds before `now`.
    @discardableResult
    private func put(_ name: String, in paths: SSHPaths, age: TimeInterval, now: Date) throws -> URL {
        let file = paths.downloads.appendingPathComponent(name)
        try Data(name.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
        return file
    }

    private func names(_ paths: SSHPaths) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: paths.downloads.path))
    }

    private static func build(_ n: Int) -> String { "\(artifact)-\(String(format: "%012x", n))" }

    @Test func keepsTheBuildInUseAndTheLastTwoUsed() throws {
        let paths = try cache()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let now = Date()
        for n in 1...10 { try put(Self.build(n), in: paths, age: TimeInterval(n * 3600), now: now) }
        // The oldest build is the one in use now (a reinstall of an old commit): it stays.
        let inUse = paths.downloads.appendingPathComponent(Self.build(10))
        paths.pruneDownloads(using: inUse, now: now)
        #expect(try names(paths) == [Self.build(10), Self.build(1), Self.build(2)])
        let used = try FileManager.default.attributesOfItem(atPath: inUse.path)[.modificationDate] as? Date
        #expect(used == now, "the build in use is marked used now")
    }

    @Test func leavesOtherArtifactsAndFreshPartials() throws {
        let paths = try cache()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let now = Date()
        let other = "cmux-tui-aarch64-apple-darwin-\(String(repeating: "a", count: 12))"
        try put(other, in: paths, age: 99 * 86_400, now: now)
        try put("\(Self.build(7)).partial", in: paths, age: 600, now: now)
        try put("\(Self.build(8)).partial", in: paths, age: 2 * 86_400, now: now)
        try put("\(Self.artifact)-notacommit", in: paths, age: 99 * 86_400, now: now)
        for n in 1...5 { try put(Self.build(n), in: paths, age: TimeInterval(n * 60), now: now) }
        paths.pruneDownloads(using: paths.downloads.appendingPathComponent(Self.build(1)), now: now)
        #expect(try names(paths) == [other, "\(Self.build(7)).partial", "\(Self.artifact)-notacommit",
                                     Self.build(1), Self.build(2), Self.build(3)])
    }
}
