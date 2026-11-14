import CmuxNextCompat
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

    private static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// The probe's listing (2026-11-11): `cmux/<bundle id>/cloud-next/{device-id,link-state}` and
    /// `client-config/<origin>.json`. Classic NIGHTLY shares the bundle id and keeps its file-fallback
    /// sign-in (`credentials.json`) in the same folder: that one stays.
    @Test func nextsItemsInTheBundleFolderMoveOnceAndClassicsSignInStays() throws {
        let support = try Self.support()
        defer { try? FileManager.default.removeItem(at: support) }
        let bundle = "com.cmuxterm.app.nightly"
        let old = support.appending(path: "cmux/\(bundle)"), new = support.appending(path: "cmux-next/\(bundle)")
        try Self.write("mac-1", old.appending(path: "cloud-next/device-id"))
        try Self.write("state", old.appending(path: "cloud-next/link-state/a"))
        try Self.write("{}", old.appending(path: "client-config/6f.json"))
        try Self.write("{\"name\":\"prod\"}", old.appending(path: "cloud-environment.json"))
        try Self.write("id", old.appending(path: "ssh-next/link-state/client"))
        try Self.write("scoped", old.appending(path: "backend-0/credentials.json"))
        try Self.write("classic", old.appending(path: "credentials.json"))
        // NEXT's own folder for the bundle may already hold other files (What's New's last update).
        try Self.write("{}", new.appending(path: "last-update.json"))

        let move = ClassicFolderItemsMove(applicationSupport: support)
        let outcomes = move.moveBundleItems(bundleID: bundle)
        #expect(outcomes == ["cloud-next": .moved, "cloud-environment.json": .moved, "client-config": .moved,
                             "ssh-next": .moved, "backend-0": .moved])
        #expect(try Self.read(new.appending(path: "cloud-next/device-id")) == "mac-1")
        #expect(try Self.read(new.appending(path: "client-config/6f.json")) == "{}")
        #expect(try Self.read(new.appending(path: "cloud-environment.json")) == "{\"name\":\"prod\"}")
        #expect(try Self.read(new.appending(path: "ssh-next/link-state/client")) == "id")
        #expect(try Self.read(new.appending(path: "backend-0/credentials.json")) == "scoped")
        #expect(try Self.read(new.appending(path: "last-update.json")) == "{}")
        // A daemon or CLI from before the move still finds each item through the link left behind.
        for name in ["cloud-next", "cloud-environment.json", "client-config", "ssh-next", "backend-0"] {
            #expect(Self.isLink(old.appending(path: name)), "\(name)")
        }
        #expect(try Self.read(old.appending(path: "cloud-next/device-id")) == "mac-1")
        // Classic's sign-in is never touched.
        #expect(try Self.read(old.appending(path: "credentials.json")) == "classic")
        #expect(!Self.isLink(old.appending(path: "credentials.json")))
        #expect(!FileManager.default.fileExists(atPath: new.appending(path: "credentials.json").path))
        // Once: the links are not moved again.
        #expect(move.moveBundleItems(bundleID: bundle).values.allSatisfy { $0 == .nothing })
        // The resolvers read the new place.
        let next = NextSupport(applicationSupport: support)
        #expect(next.bundleFolder(bundleID: bundle).standardizedFileURL == new.standardizedFileURL)
        #expect(next.classicBundleFolder(bundleID: bundle).standardizedFileURL == old.standardizedFileURL)
    }

    @Test func aBundleItemAlreadyInUseIsNeverReplaced() throws {
        let support = try Self.support()
        defer { try? FileManager.default.removeItem(at: support) }
        let old = support.appending(path: "cmux/b"), new = support.appending(path: "cmux-next/b")
        try Self.write("old", old.appending(path: "cloud-next/device-id"))
        try Self.write("new", new.appending(path: "cloud-next/device-id"))
        try Self.write("old", old.appending(path: "cloud-environment.json"))
        try Self.write("new", new.appending(path: "cloud-environment.json"))

        let outcomes = ClassicFolderItemsMove(applicationSupport: support).moveBundleItems(bundleID: "b")
        guard case .kept = outcomes["cloud-next"], case .kept = outcomes["cloud-environment.json"] else {
            Issue.record("a move over a used bundle item: \(outcomes)")
            return
        }
        #expect(try Self.read(old.appending(path: "cloud-next/device-id")) == "old")
        #expect(try Self.read(new.appending(path: "cloud-next/device-id")) == "new")
        #expect(try Self.read(old.appending(path: "cloud-environment.json")) == "old")
        #expect(try Self.read(new.appending(path: "cloud-environment.json")) == "new")
    }

    @Test func noBundleFolderNothingMoves() throws {
        let support = try Self.support()
        defer { try? FileManager.default.removeItem(at: support) }
        #expect(ClassicFolderItemsMove(applicationSupport: support).moveBundleItems(bundleID: "b").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "cmux").path))
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "cmux-next").path))
    }

    /// A link socket's name hashes its root: a moved root keeps the name from before the move.
    @Test func aMovedBundleFolderPathKeepsItsNameFromBeforeTheMove() {
        let before = "/Users/a/Library/Application Support/cmux/com.cmuxterm.app.nightly/ssh-next"
        let after = "/Users/a/Library/Application Support/cmux-next/com.cmuxterm.app.nightly/ssh-next"
        #expect(NextSupport.pathIdentity(after) == before)
        #expect(NextSupport.pathIdentity(before) == before)
        #expect(NextSupport.pathIdentity("/tmp/x") == "/tmp/x")
    }
}
