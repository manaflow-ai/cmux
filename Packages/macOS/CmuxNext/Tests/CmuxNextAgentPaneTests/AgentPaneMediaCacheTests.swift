@testable import CmuxNextAgentPane
import Darwin
import Foundation
import Testing

/// Real files and independent kernel leases: a new cache stands in for an app restart.
/// No test reads or sweeps the user's actual media cache.
nonisolated struct AgentPaneMediaCacheTests {
    private static let clip = Data([0, 0, 0, 0x18]) + Data("ftypisom".utf8) + Data(repeating: 7, count: 64)

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "media-cache-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    @Test func restartReclaimsAbandonedClipsButKeepsLiveOwnersAndRanges() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let abandoned = AgentPaneMediaCache(root: root)
        let old = try #require(await abandoned.store(Self.clip, ext: "mp4"))
        let live = AgentPaneMediaCache(root: root)
        let playing = try #require(await live.store(Self.clip, ext: "mp4"))
        // A second process starting while the first runs must not mistake either owner for an orphan.
        #expect(FileManager.default.fileExists(atPath: old.path))
        await abandoned.finish()
        let restarted = AgentPaneMediaCache(root: root)
        let fresh = try #require(await restarted.store(Self.clip, ext: "mp4"))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: old.deletingLastPathComponent().path))
        #expect(try Data(contentsOf: fresh) == Self.clip)
        // Exercise a NEW range read after cleanup, not a descriptor opened before the sweep.
        let slice = await AgentPaneSchemeHandler.readSlice(of: playing, range: "bytes=12-31")
        #expect(slice?.status == 206)
        #expect(slice?.data == Self.clip.subdata(in: 12..<32))
        await live.finish()
        await restarted.finish()
    }

    @Test func evictionRemovesOnlyTheOwningCachesClip() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = AgentPaneMediaCache(root: root), second = AgentPaneMediaCache(root: root)
        let own = try #require(await first.store(Self.clip, ext: "mp4"))
        let other = try #require(await second.store(Self.clip, ext: "mp4"))
        let local = root.appending(path: "user.mp4")
        try Self.clip.write(to: local)
        await first.remove(other)
        await first.remove(local)
        await first.remove(own)
        #expect(!FileManager.default.fileExists(atPath: own.path))
        #expect(try Data(contentsOf: other) == Self.clip)
        #expect(try Data(contentsOf: local) == Self.clip)
        await first.finish()
        await second.finish()
    }

    @Test func legacyFilesUnknownEntriesAndSymlinksAreNeverSwept() async throws {
        let root = try fixture(), outside = try fixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let legacy = root.appending(path: UUID().uuidString.lowercased() + ".mp4")
        let target = outside.appending(path: "precious.mp4")
        try Self.clip.write(to: legacy)
        try Self.clip.write(to: target)
        let old = AgentPaneMediaCache(root: root)
        let file = try #require(await old.store(Self.clip, ext: "mp4"))
        let owner = file.deletingLastPathComponent()
        let unknown = owner.appending(path: "keep.txt")
        try Data("unknown".utf8).write(to: unknown)
        let symlink = owner.appending(path: UUID().uuidString.lowercased() + ".mp4")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let linkedOwner = root.appending(path: "v1-" + UUID().uuidString.lowercased())
        try FileManager.default.createSymbolicLink(at: linkedOwner, withDestinationURL: outside)
        await old.finish()
        let next = AgentPaneMediaCache(root: root)
        _ = try #require(await next.store(Self.clip, ext: "mp4"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: legacy) == Self.clip)
        #expect(try Data(contentsOf: target) == Self.clip)
        #expect(try Data(contentsOf: unknown) == Data("unknown".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path) == target.path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linkedOwner.path) == outside.path)
        await next.finish()
    }

    @Test func missingOrInvalidOwnershipProofPreservesClips() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = AgentPaneMediaCache(root: root)
        let file = try #require(await old.store(Self.clip, ext: "mp4"))
        await old.finish()
        let lease = root.appending(path: "." + file.deletingLastPathComponent().lastPathComponent + ".lock")
        try FileManager.default.removeItem(at: lease)
        let next = AgentPaneMediaCache(root: root)
        _ = try #require(await next.store(Self.clip, ext: "mp4"))
        #expect(try Data(contentsOf: file) == Self.clip)
        await next.finish()
    }

    @Test func rejectsUnsafeRootsAndExtensionsAndKeepsPrivatePermissions() async throws {
        let root = try fixture(), target = try fixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: target)
        }
        let linkedRoot = root.appending(path: "linked")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: target)
        let refused = AgentPaneMediaCache(root: linkedRoot)
        #expect(await refused.store(Self.clip, ext: "mp4") == nil)
        let cache = AgentPaneMediaCache(root: root)
        #expect(await cache.store(Self.clip, ext: "../../escape") == nil)
        #expect(await cache.store(Data("not media".utf8), ext: "mp4") == nil)
        let file = try #require(await cache.store(Self.clip, ext: "mp4"))
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(folderMode == 0o700)
        await cache.finish()
        #expect(await cache.store(Self.clip, ext: "mp4") == nil)
    }

    @Test func concurrentOwnersDoNotReclaimOneAnother() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let owners = (0..<8).map { _ in AgentPaneMediaCache(root: root) }
        let files = await withTaskGroup(of: URL?.self, returning: [URL].self) { group in
            for owner in owners { group.addTask { await owner.store(Self.clip, ext: "mp4") } }
            var files: [URL] = []
            for await file in group { if let file { files.append(file) } }
            return files
        }
        #expect(files.count == owners.count)
        #expect(Set(files.map { $0.deletingLastPathComponent() }).count == owners.count)
        for file in files { #expect(try Data(contentsOf: file) == Self.clip) }
        for owner in owners { await owner.finish() }
    }
}
