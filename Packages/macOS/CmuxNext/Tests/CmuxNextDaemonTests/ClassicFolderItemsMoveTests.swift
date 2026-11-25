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
        // The ledger and the drafts move; the other folders are not there.
        #expect(move.run() == [.moved, .moved] + Array(repeating: .nothing, count: ClassicFolderItemsMove.folders.count - 2))
        #expect(try Self.read(support.appending(path: "cmux-next/recovery/a.draft")) == "draft")
        #expect(try Self.read(support.appending(path: "cmux-next/server-fix-ledger/com.cmuxterm.app.nightly.server-helper.json")) == "{}")
        // An older build (a rollback) still finds its drafts through the old path.
        #expect(try Self.read(support.appending(path: "cmux/recovery/a.draft")) == "draft")
        #expect(try Self.read(support.appending(path: "cmux/session-com.cmuxterm.app.json")) == "classic")
        // Once: the links left behind are not moved again.
        #expect(move.run() == Array(repeating: StateFolderMove.Outcome.nothing, count: ClassicFolderItemsMove.folders.count))
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
        #expect(move.run() == Array(repeating: StateFolderMove.Outcome.nothing, count: ClassicFolderItemsMove.folders.count))
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

    /// The Computer Use helper's runtime folder (its agent token and state) leaves classic's
    /// `cmux/cmux-cua/runtime/<scope>` once; other scopes' folders and the shared `helper` copies stay.
    @Test func theComputerUseRuntimeFolderMovesOnceWithALinkBack() throws {
        let support = try Self.support()
        defer { try? FileManager.default.removeItem(at: support) }
        // The scope the nightly probe found in classic's folder (2026-11-15): the name must not change,
        // so the helper keeps its agent token across the move.
        #expect(NextSupport.computerUseScope("com.cmuxterm.app.nightly") == "73ff36dc45525a51")
        let old = support.appending(path: "cmux/cmux-cua/runtime/73ff36dc45525a51")
        try Self.write("token", old.appending(path: "agent-token"))
        try Self.write("s", old.appending(path: "state/x"))
        try Self.write("other", support.appending(path: "cmux/cmux-cua/runtime/0000000000000000/agent-token"))
        try Self.write("copy", support.appending(path: "cmux/cmux-cua/helper/next-73ff36dc45525a51/x"))

        let move = ClassicFolderItemsMove(applicationSupport: support)
        #expect(move.moveComputerUseRuntime(bundleID: "com.cmuxterm.app.nightly") == .moved)
        let new = NextSupport(applicationSupport: support).computerUseRuntime(bundleID: "com.cmuxterm.app.nightly")
        #expect(new.path == support.appending(path: "cmux-next/cmux-cua/runtime/73ff36dc45525a51").path)
        #expect(try Self.read(new.appending(path: "agent-token")) == "token")
        #expect(try Self.read(new.appending(path: "state/x")) == "s")
        // A helper an older app started still finds its state through the old path.
        #expect(try Self.read(old.appending(path: "state/x")) == "s")
        #expect(try Self.read(support.appending(path: "cmux/cmux-cua/runtime/0000000000000000/agent-token")) == "other")
        #expect(try Self.read(support.appending(path: "cmux/cmux-cua/helper/next-73ff36dc45525a51/x")) == "copy")
        #expect(move.moveComputerUseRuntime(bundleID: "com.cmuxterm.app.nightly") == .nothing)
    }

    /// The helper copies this build staged in classic's `cmux/cmux-cua/helper` move once to `cmux-next`, with no
    /// link left: an older build refuses a staging folder behind a link, and with none it just stages again.
    /// Classic's own copies and other scopes' stay.
    @Test func theComputerUseHelperCopiesMoveOnceWithNoLink() throws {
        let support = try Self.support()
        defer { try? FileManager.default.removeItem(at: support) }
        let helper = support.appending(path: "cmux/cmux-cua/helper")
        try Self.write("legacy", helper.appending(path: "next-73ff36dc45525a51/cmux Computer Use.app/x"))
        try Self.write("v2", helper.appending(path: "next-v2-73ff36dc45525a51/v2.app/x"))
        try Self.write("classic", helper.appending(path: "cmux Computer Use.app/x"))
        try Self.write("other", helper.appending(path: "next-0000000000000000/x"))

        let move = ClassicFolderItemsMove(applicationSupport: support)
        #expect(move.moveComputerUseCopies(bundleID: "com.cmuxterm.app.nightly") == [.moved, .moved])
        let new = NextSupport(applicationSupport: support).folder.appending(path: "cmux-cua/helper")
        #expect(try Self.read(new.appending(path: "next-73ff36dc45525a51/cmux Computer Use.app/x")) == "legacy")
        #expect(try Self.read(new.appending(path: "next-v2-73ff36dc45525a51/v2.app/x")) == "v2")
        var info = stat()
        #expect(lstat(helper.appending(path: "next-73ff36dc45525a51").path, &info) != 0)
        #expect(lstat(helper.appending(path: "next-v2-73ff36dc45525a51").path, &info) != 0)
        #expect(try Self.read(helper.appending(path: "cmux Computer Use.app/x")) == "classic")
        #expect(try Self.read(helper.appending(path: "next-0000000000000000/x")) == "other")
        #expect(move.moveComputerUseCopies(bundleID: "com.cmuxterm.app.nightly") == [.nothing, .nothing])
    }

    @Test func aComputerUseCopyAlreadyStagedInNextIsNeverReplaced() throws {
        let support = try Self.support()
        defer { try? FileManager.default.removeItem(at: support) }
        try Self.write("old", support.appending(path: "cmux/cmux-cua/helper/next-73ff36dc45525a51/x"))
        try Self.write("new", support.appending(path: "cmux-next/cmux-cua/helper/next-73ff36dc45525a51/y"))
        let outcomes = ClassicFolderItemsMove(applicationSupport: support).moveComputerUseCopies(bundleID: "com.cmuxterm.app.nightly")
        guard case .kept = outcomes[0] else {
            Issue.record("a move over a staged copy: \(outcomes)")
            return
        }
        #expect(try Self.read(support.appending(path: "cmux-next/cmux-cua/helper/next-73ff36dc45525a51/y")) == "new")
    }

    @Test func aFreshHomeGetsNoComputerUseFolderInClassics() throws {
        let support = try Self.support()
        defer { try? FileManager.default.removeItem(at: support) }
        #expect(ClassicFolderItemsMove(applicationSupport: support).moveComputerUseRuntime(bundleID: "com.cmuxterm.app.nightly") == .nothing)
        #expect(ClassicFolderItemsMove(applicationSupport: support).moveComputerUseCopies(bundleID: "com.cmuxterm.app.nightly") == [.nothing, .nothing])
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "cmux").path))
    }

    /// A link socket's name hashes its root: a moved root keeps the name from before the move.
    @Test func aMovedBundleFolderPathKeepsItsNameFromBeforeTheMove() {
        let before = "/Users/a/Library/Application Support/cmux/com.cmuxterm.app.nightly/ssh-next"
        let after = "/Users/a/Library/Application Support/cmux-next/com.cmuxterm.app.nightly/ssh-next"
        #expect(NextSupport.pathIdentity(after) == before)
        #expect(NextSupport.pathIdentity(before) == before)
        #expect(NextSupport.pathIdentity("/tmp/x") == "/tmp/x")
    }

    /// NEXT's own files leave classic's `~/.config/cmux` once; classic's cmux.json, its skill and
    /// cmux-tui.json (copied, not moved) stay where classic reads them.
    @Test func nextsConfigFilesLeaveClassicsConfigFolderOnce() throws {
        let home = try Self.support()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = BuildStatePaths(build: BuildIdentity(bundleID: "com.cmuxterm.app.nightly", bundledTag: nil), userHome: home,
                                    applicationSupport: home.appending(path: "Library/Application Support"),
                                    caches: home.appending(path: "Library/Caches"))
        let old = home.appending(path: ".config/cmux"), new = home.appending(path: ".config/cmux-next")
        try Self.write("next", old.appending(path: "cmux-next.json"))
        try Self.write("classic", old.appending(path: "cmux.json"))
        try Self.write("tui", old.appending(path: "cmux-tui.json"))
        try Self.write("auto", old.appending(path: "automations/a.json"))
        try Self.write("mine", old.appending(path: "skills/mine.md"))
        try Self.write("cloud", old.appending(path: "skills/cmux-cloud.md"))

        let outcomes = ClassicFolderItemsMove.moveConfigItems(paths: paths)
        #expect(outcomes["cmux-next.json"] == .moved)
        #expect(try Self.read(new.appending(path: "cmux-next.json")) == "next")
        #expect(try Self.read(new.appending(path: "automations/a.json")) == "auto")
        #expect(try Self.read(new.appending(path: "skills/mine.md")) == "mine")
        #expect(try Self.read(new.appending(path: "cmux-tui.json")) == "tui")
        #expect(try Self.read(old.appending(path: "cmux-tui.json")) == "tui")
        #expect(try Self.read(old.appending(path: "cmux.json")) == "classic")
        #expect(try Self.read(old.appending(path: "skills/cmux-cloud.md")) == "cloud")
        #expect(!FileManager.default.fileExists(atPath: old.appending(path: "cmux-next.json").path))
        #expect(!FileManager.default.fileExists(atPath: new.appending(path: "skills/cmux-cloud.md").path))
        // Once: a second launch finds nothing of NEXT's left to move.
        #expect(ClassicFolderItemsMove.moveConfigItems(paths: paths).values.allSatisfy { $0 == .nothing })
    }

    /// The folders BuildStatePaths and the Rust defaults now keep in `cmux-next` (agent homes, chat
    /// attachments, cmux-remote's identity, the browser host's backups, cmux-tasks' store) move once, each
    /// leaving a link: chats and agent configs name agent-home and Chat Uploads paths.
    @Test func theApplicationSupportFoldersMoveOnceWithALinkBack() throws {
        let support = try Self.support()
        defer { try? FileManager.default.removeItem(at: support) }
        let moved = ["agent-home", "Chat Uploads", "remote", "browser-host", "tasks"]
        for name in moved { try Self.write(name, support.appending(path: "cmux/\(name)/f")) }
        try Self.write("classic", support.appending(path: "cmux/session-com.cmuxterm.app.json"))

        let move = ClassicFolderItemsMove(applicationSupport: support)
        let outcomes = move.run()
        for (name, outcome) in zip(ClassicFolderItemsMove.folders, outcomes) {
            #expect(outcome == (moved.contains(name) ? StateFolderMove.Outcome.moved : .nothing), "\(name)")
        }
        for name in moved {
            #expect(try Self.read(support.appending(path: "cmux-next/\(name)/f")) == name)
            // A chat naming the old path still reads its file through the link.
            #expect(Self.isLink(support.appending(path: "cmux/\(name)")), "\(name)")
            #expect(try Self.read(support.appending(path: "cmux/\(name)/f")) == name)
        }
        #expect(try Self.read(support.appending(path: "cmux/session-com.cmuxterm.app.json")) == "classic")
        #expect(move.run() == Array(repeating: StateFolderMove.Outcome.nothing, count: ClassicFolderItemsMove.folders.count))
    }

    private static func nightlyPaths(home: URL) -> BuildStatePaths {
        BuildStatePaths(build: BuildIdentity(bundleID: "com.cmuxterm.app.nightly", bundledTag: nil), userHome: home,
                        applicationSupport: home.appending(path: "Library/Application Support"),
                        caches: home.appending(path: "Library/Caches"))
    }

    /// git records each worktree's path, so the GitHub feed's worktrees keep a link at the old path; the
    /// other config folders move with none.
    @Test func githubWorktreesKeepALinkAndOtherConfigFoldersDoNot() throws {
        let home = try Self.support()
        defer { try? FileManager.default.removeItem(at: home) }
        let old = home.appending(path: ".config/cmux"), new = home.appending(path: ".config/cmux-next")
        try Self.write("gitdir", old.appending(path: "github-worktrees/repo/.git"))
        try Self.write("auto", old.appending(path: "automations/a.json"))

        let outcomes = ClassicFolderItemsMove.moveConfigItems(paths: Self.nightlyPaths(home: home))
        #expect(outcomes["github-worktrees"] == .moved)
        #expect(outcomes["automations"] == .moved)
        #expect(try Self.read(new.appending(path: "github-worktrees/repo/.git")) == "gitdir")
        #expect(Self.isLink(old.appending(path: "github-worktrees")))
        #expect(try Self.read(old.appending(path: "github-worktrees/repo/.git")) == "gitdir")
        var info = stat()
        #expect(lstat(old.appending(path: "automations").path, &info) != 0)
        #expect(try Self.read(new.appending(path: "automations/a.json")) == "auto")
        // Once: the link is not moved again.
        #expect(ClassicFolderItemsMove.moveConfigItems(paths: Self.nightlyPaths(home: home))["github-worktrees"] == nil)
    }

    /// A config file, folder, skill or copy already at the new path is never replaced: both stay as they were.
    @Test func aConfigItemAlreadyInCmuxNextIsNeverReplaced() throws {
        let home = try Self.support()
        defer { try? FileManager.default.removeItem(at: home) }
        let old = home.appending(path: ".config/cmux"), new = home.appending(path: ".config/cmux-next")
        for item in ["cmux-next.json", "automations/a.json", "skills/mine.md", "cmux-tui.json"] {
            try Self.write("old", old.appending(path: item))
            try Self.write("new", new.appending(path: item))
        }

        let outcomes = ClassicFolderItemsMove.moveConfigItems(paths: Self.nightlyPaths(home: home))
        for key in ["cmux-next.json", "automations", "skills/mine.md"] {
            guard case .kept = outcomes[key] else {
                Issue.record("a move over \(key) in cmux-next: \(outcomes)")
                continue
            }
        }
        // The copy is skipped, not attempted, when cmux-next has its own.
        #expect(outcomes["cmux-tui.json"] == nil)
        for item in ["cmux-next.json", "automations/a.json", "skills/mine.md", "cmux-tui.json"] {
            #expect(try Self.read(old.appending(path: item)) == "old", "\(item)")
            #expect(try Self.read(new.appending(path: item)) == "new", "\(item)")
        }
    }
}
