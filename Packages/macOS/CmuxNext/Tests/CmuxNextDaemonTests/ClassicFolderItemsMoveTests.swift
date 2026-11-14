import Foundation
import Testing
@testable import CmuxNextDaemon

/// The loose items NEXT kept in classic cmux's `Application Support/cmux` leave it once
/// (cmuxterm-hq goals/next-store-out-of-classic.md); classic's own files stay.
struct ClassicFolderItemsMoveTests {
    private static func support() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "items-move-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private static func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test func draftsAndTheLedgerMoveOnceWithALinkBack() throws {
        let support = try Self.support()
        defer { try? FileManager.default.removeItem(at: support) }
        try Self.write("draft", support.appending(path: "cmux/recovery/a.draft"))
        try Self.write("{}", support.appending(path: "cmux/server-fix-ledger/com.cmuxterm.app.nightly.server-helper.json"))
        try Self.write("classic", support.appending(path: "cmux/session-com.cmuxterm.app.json"))

        let move = ClassicFolderItemsMove(applicationSupport: support)
        #expect(move.run() == [.moved, .moved])
        #expect(try Self.read(support.appending(path: "cmux-next/recovery/a.draft")) == "draft")
        #expect(try Self.read(support.appending(path: "cmux-next/server-fix-ledger/com.cmuxterm.app.nightly.server-helper.json")) == "{}")
        // An older build (a rollback) still finds its drafts through the old path.
        #expect(try Self.read(support.appending(path: "cmux/recovery/a.draft")) == "draft")
        #expect(try Self.read(support.appending(path: "cmux/session-com.cmuxterm.app.json")) == "classic")
        // Once: the links left behind are not moved again.
        #expect(move.run() == [.nothing, .nothing])
    }

    @Test func aFolderOrFileAlreadyInUseIsNeverReplaced() throws {
        let support = try Self.support()
        defer { try? FileManager.default.removeItem(at: support) }
        try Self.write("old", support.appending(path: "cmux/recovery/a.draft"))
        try Self.write("new", support.appending(path: "cmux-next/recovery/b.draft"))
        try Self.write("old", support.appending(path: "cmux/dev/debug-tunables.json"))
        try Self.write("new", support.appending(path: "cmux-next/dev/debug-tunables.json"))

        let move = ClassicFolderItemsMove(applicationSupport: support)
        guard case .kept = move.run()[1] else {
            Issue.record("a move over a used drafts folder")
            return
        }
        guard case .kept = move.moveFile("dev/debug-tunables.json") else {
            Issue.record("a move over a used Debug Settings file")
            return
        }
        #expect(try Self.read(support.appending(path: "cmux/recovery/a.draft")) == "old")
        #expect(try Self.read(support.appending(path: "cmux-next/recovery/b.draft")) == "new")
        #expect(try Self.read(support.appending(path: "cmux/dev/debug-tunables.json")) == "old")
        #expect(try Self.read(support.appending(path: "cmux-next/dev/debug-tunables.json")) == "new")
    }

    @Test func aKeptNameBuildsDebugSettingsFileMovesOnlyToTheFileItReads() throws {
        let support = try Self.support()
        defer { try? FileManager.default.removeItem(at: support) }
        try Self.write("{}", support.appending(path: "cmux/feature/debug-tunables.json"))
        let move = ClassicFolderItemsMove(applicationSupport: support)
        #expect(ClassicFolderItemsMove.debugTunables(tag: "feature", bundleID: nil) == "feature/debug-tunables.json")
        #expect(ClassicFolderItemsMove.debugTunables(tag: nil, bundleID: "com.cmuxterm.app.nightly") == "nightly/debug-tunables.json")
        // An override, or a per-key build's file beside its daemon state: nothing moves.
        #expect(move.moveDebugTunables(to: URL(fileURLWithPath: "/tmp/override.json"), tag: "feature", bundleID: nil) == .nothing)
        let tagged = support.appending(path: "cmux-next/tags/feature/debug-tunables.json")
        #expect(move.moveDebugTunables(to: tagged, tag: "feature", bundleID: nil) == .nothing)
        let kept = support.appending(path: "cmux-next/feature/debug-tunables.json")
        #expect(move.moveDebugTunables(to: kept, tag: "feature", bundleID: nil) == .moved)
        #expect(try Self.read(kept) == "{}")
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "cmux/feature/debug-tunables.json").path))
        #expect(move.moveDebugTunables(to: kept, tag: "feature", bundleID: nil) == .nothing)
    }

    @Test func nothingToMoveOnAFreshMac() throws {
        let support = try Self.support()
        defer { try? FileManager.default.removeItem(at: support) }
        let move = ClassicFolderItemsMove(applicationSupport: support)
        #expect(move.run() == [.nothing, .nothing])
        #expect(move.moveFile("dev/debug-tunables.json") == .nothing)
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "cmux").path))
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "cmux-next").path))
    }
}
