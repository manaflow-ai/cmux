import Foundation
@testable import CmuxNextUpdater
import Testing

/// Going back to the previous build (Leo 2026-11-11: reverting to the previous nightly was slow and
/// sometimes did not work). The pick is by build number and keep date, never the folder's order and
/// never forward; a kept build's record spares the click a whole-bundle signature check; a keep or
/// swap cut short is tidied at launch.
@Suite(.serialized) struct RollbackGoBackTests {
    private static func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "RollbackGoBackTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A bundle with an executable and a signature file (the record's fingerprint reads both).
    private static func makeBundle(at url: URL, build: String) throws {
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appending(path: "_CodeSignature"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleVersion": build, "CFBundleShortVersionString": "1.0.0-nightly.\(build)",
                                  "CFBundleExecutable": "cmux"]
        try info.write(to: contents.appending(path: "Info.plist"))
        try Data("bin".utf8).write(to: contents.appending(path: "MacOS/cmux"))
        try Data("sig".utf8).write(to: contents.appending(path: "_CodeSignature/CodeResources"))
    }

    private static func kept(_ build: String, keptAt: TimeInterval?) -> KeptVersion {
        KeptVersion(build: build, shortVersion: "1.0.0-nightly.\(build)", bundle: URL(fileURLWithPath: "/kept/\(build)/cmux.app"),
                    storeSchemas: [:], teamID: "TEAM", keptAt: keptAt.map(Date.init(timeIntervalSince1970:)))
    }

    /// After going back from 300 to 200, 300 is kept and newer: going back again must not go
    /// forward to it (the harness's twice-rollback did, before).
    @Test func goingBackNeverGoesForward() {
        let list = [Self.kept("300", keptAt: 20), Self.kept("100", keptAt: 5)]
        #expect(RollbackDecision.previous(kept: list, running: "200")?.build == "100")
        let decided = RollbackDecision.decide(kept: list, build: nil, running: "200", stored: [:], teamID: "TEAM")
        #expect((try? decided.get())?.build == "100")
        let none = RollbackDecision.decide(kept: [Self.kept("300", keptAt: 20)], build: nil, running: "200", stored: [:], teamID: "TEAM")
        #expect(none == .failure(.nothingOlder(running: "200")))
    }

    /// Of the older builds, the one kept last is the one this Mac came from; numbers compare as
    /// numbers (1000 is above 999), and the folder's order counts for nothing.
    @Test func thePreviousBuildIsTheOneKeptLast() {
        let list = [Self.kept("150", keptAt: 1), Self.kept("180", keptAt: 30), Self.kept("170", keptAt: 10)]
        #expect(RollbackDecision.previous(kept: list, running: "200")?.build == "180")
        let mixed = [Self.kept("999", keptAt: nil), Self.kept("1000", keptAt: nil), Self.kept("90", keptAt: nil)]
        #expect(RollbackDecision.previous(kept: mixed, running: "1001")?.build == "1000")
        #expect(RollbackDecision.previous(kept: mixed, running: "999")?.build == "90")
    }

    /// The keep checks every file once, off the click, and seals what it read: listing the kept
    /// build then checks no whole bundle while the seal matches, and checks every file again once
    /// anything in the bundle changed, a bundled script included (cmux#41013 review: a fingerprint of
    /// the signature files alone let a changed resource through a check that skipped resources).
    @Test(arguments: ["Contents/Resources/app.js", "Contents/_CodeSignature/CodeResources", "Contents/MacOS/cmux"])
    func theSealSparesTheFullCheckUntilAnyFileChanges(changed: String) throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let full = Counter(), quick = Counter()
        let store = KeptVersionStore(root: root.appending(path: "versions"), teamID: { _ in full.add(); return "TEAM" },
                                     quickTeamID: { _ in quick.add(); return "TEAM" })
        let app = root.appending(path: "a/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: app, build: "100")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        try Data("ok()".utf8).write(to: app.appending(path: "Contents/Resources/app.js"))
        try store.keep(bundle: app, build: "100", limit: 2, record: KeptRecord(build: "100", date: "2026-11-10", storeSchemas: ["chats": 3]))
        #expect(full.value == 1, "the keep checks every file once")
        let listed = try #require(store.list(teams: false).first)
        #expect(store.checkedTeam(of: listed) == "TEAM")
        #expect(listed.storeSchemas == ["chats": 3] && listed.date == "2026-11-10")
        #expect(full.value == 1 && quick.value == 1, "the click checks only the executable")
        let file = listed.bundle.appending(path: changed)
        var bytes = try Data(contentsOf: file)
        bytes.append(contentsOf: Array("//".utf8))
        try bytes.write(to: file)
        #expect(store.checkedTeam(of: listed) == "TEAM")
        #expect(full.value == 2, "a changed file is checked in full again")
    }

    /// A keep made at a click (the swap) checks nothing then: the copy has no trusted team until
    /// the next launch checks every file and seals it.
    @Test func aKeepAtTheClickIsSealedAtTheNextLaunch() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let full = Counter()
        let store = KeptVersionStore(root: root.appending(path: "versions"), teamID: { _ in full.add(); return "TEAM" },
                                     quickTeamID: { _ in "TEAM" })
        let app = root.appending(path: "a/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: app, build: "100")
        try store.keep(bundle: app, build: "100", limit: 2, record: KeptRecord(build: "100", teamID: "TEAM"), check: .later)
        #expect(full.value == 0)
        #expect(store.list(teams: false).first?.teamID == nil, "a team nobody checked is not recorded")
        #expect(store.sealPending() == ["100"])
        #expect(store.sealPending().isEmpty, "sealed once")
        let listed = try #require(store.list(teams: false).first)
        #expect(listed.teamID == "TEAM" && store.checkedTeam(of: listed) == "TEAM")
        #expect(full.value == 1)
    }

    /// A kept build's code runs once after the keep (macOS checks a new bundle at its first run, so
    /// going back to it later does not wait on that), and again at launch when a quit cut it short.
    @Test func aKeptBuildRunsOnceSoGoingBackIsNotItsFirstLaunch() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KeptVersionStore(root: root.appending(path: "versions"), teamID: { _ in "TEAM" }, quickTeamID: { _ in "TEAM" })
        let app = root.appending(path: "a/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: app, build: "100")
        let cli = app.appending(path: "Contents/Resources/bin/cmux")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        let runs = root.appending(path: "runs")
        try Data("#!/bin/sh\necho run >> '\(runs.path)'\necho '{\"sessions\": 3}'\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        try store.keep(bundle: app, build: "100", limit: 2, record: KeptRecord(build: "100", teamID: "TEAM"))
        let log = UpdateLogBuffer()
        await KeptWarmup.warmPending(store: store, log: log)
        await KeptWarmup.warmPending(store: store, log: log)
        let ran = try String(contentsOf: runs, encoding: .utf8).split(separator: "\n")
        #expect(ran.count == 1, "runs once, and the record says so")
        let listed = try #require(store.list(teams: false).first)
        #expect(listed.storeSchemas == ["sessions": 3], "its answer is the stores it reads")
        #expect(store.checkedTeam(of: listed) == "TEAM", "the run leaves the seal as it was")
    }

    /// The prune keeps the builds kept most recently, so the build this Mac came from stays even
    /// when its number is lower than one kept before it.
    @Test func thePruneKeepsWhatWasKeptLast() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        var store = KeptVersionStore(root: root.appending(path: "versions"), teamID: { _ in "TEAM" })
        for (build, at) in [("300", 10.0), ("100", 20.0)] {
            let app = root.appending(path: "\(build)/cmux.app", directoryHint: .isDirectory)
            try Self.makeBundle(at: app, build: build)
            store.now = { Date(timeIntervalSince1970: at) }
            try store.keep(bundle: app, build: build, limit: 1)
        }
        #expect(store.list(teams: false).map(\.build) == ["100"])
    }

    /// A clone cut short (a folder with only `.partial`) and a kept bundle a swap left beside the
    /// app are tidied at launch: the bundle goes back into the store, the empty folder goes.
    @Test func whatACutShortKeepOrSwapLeftIsTidied() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KeptVersionStore(root: root.appending(path: "versions"), teamID: { _ in "TEAM" })
        let half = store.root.appending(path: "150", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: half.appending(path: ".cmux.app.partial"), withIntermediateDirectories: true)
        let app = root.appending(path: "Applications/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: app, build: "200")
        let staged = root.appending(path: "Applications/\(RollbackSwap.stagedPrefix)100-\(UUID().uuidString)-cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: staged, build: "100")

        #expect(store.sweep() == ["150"])
        #expect(RollbackSwap.recover(current: app, store: store) == ["put back 100"])
        #expect(store.list(teams: false).map(\.build) == ["100"])
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    /// The notice card names the step, and a failure says why.
    @Test func theNoticeNamesTheStep() {
        let swapping = RevertNotice(RevertProgress(step: .swapping, target: "100", label: "nightly 100 from Nov 10"))
        #expect(swapping.working && swapping.title.contains("nightly 100 from Nov 10") && swapping.detail == UpdaterStrings.revertSwapping)
        let down = RevertNotice(RevertProgress(step: .downloading, fraction: 0.42))
        #expect(down.fraction == 0.42 && down.detail?.contains("42") == true)
        let failed = RevertNotice(RevertProgress(step: .failed, failure: "why"))
        #expect(!failed.working && failed.title == UpdaterStrings.revertFailed && failed.detail == "why")
    }

    @Test func theTargetIsNamedByVersionAndDay() {
        let target = RevertTarget(build: "4288034619601", version: "1.0.0-nightly.4288034619601", date: "2026-11-10", kept: true)
        #expect(target.label.hasPrefix("nightly 4288034"))
        #expect(target.label.contains("10"))
        #expect(RevertTarget(build: "1", version: "1.0.1", date: nil, kept: true).label == "1.0.1")
    }
}

nonisolated private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
